#!/usr/bin/env bash
# build-x86-host-stage4.sh
# Build a hardened Gentoo amd64 stage4 + bootable ISO for the "snapdragon-host"
# node: a headless Kubernetes worker that joins the pki Pi control-plane and
# hosts ArgoCD + the snapdragon.games namespace + backend workloads, using a
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
CLUSTER_DOMAIN="snapdragon.systems"
# Orchestration superdomain (WS-SUPER-B): the mesh control plane's MagicDNS suffix that
# every node joins. "" = builder default (legacy byte-identical: no marker, headscale keeps
# its checked-in headnet.internal base_domain). The Studio emits --superdomain <effective>
# only for MESH builds. PERMANENTLY INTERNAL — never the go-live public apex (that stays
# CLUSTER_DOMAIN); this flag is the authoritative on-image bake, the KEYS/provision channel
# handles the secret side.
SUPERDOMAIN=""
BRAND="snapdragon"
BRAND_TITLE="Snapdragon Systems"
ORG="Snapdragon-Systems"
# Games portal domain. DEFAULT serves games as a SUBDOMAIN of the primary domain
# (games.<CLUSTER_DOMAIN>) until the real .games TLD is obtained; flip to the TLD
# later with GAMES_DOMAIN=<brand>.games. The default literal "games.snapdragon.systems"
# composes with rebrand_sysroot (its snapdragon.systems->CLUSTER_DOMAIN rule turns
# it into games.<CLUSTER_DOMAIN>); a custom value is rebrand-neutral. Drives the
# games host + OIDC issuer/redirects via parameterize_games_domain(). See
# docs/OPTIONAL-SERVICES.md.
GAMES_DOMAIN="games.snapdragon.systems"
# ── DEFAULT-INCLUSION POLICY (user 2026-06-17) — mirrors build-rpi5-stage4.sh ──
# USER_LEVEL_SERVICES is the SINGLE source-of-truth set of user-level OPTIONAL
# slugs (matches specs/cluster/optional-services.yaml; excludes the non-user-level
# infra slugs egress-vpn / tor / workloadConsole / anubis). It is what
# OPTIONAL_SERVICES=all / --all-services expands to.
USER_LEVEL_SERVICES="akkoma tuwunel phpbb games owncast tube character-studio"
# OPTIONAL services selected on this image (subset of USER_LEVEL_SERVICES).
#   DEFAULT-ON  (the built-in default when NO selection is given): akkoma tuwunel phpbb.
#   DEFAULT-OFF (must be specifically added): games owncast tube character-studio.
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
# The chosen ENV is written to /etc/snapdragon/env and gates which ArgoCD apps
# survive in the baked /var/lib/snapdragon/cluster/apps tree (gate_env_apps).
ENV="test"
# ── Release-state selector (BAKED into the image, gates gate_env_apps()/
# bake_host_firewall() ingress+firewall posture) ────────────────────
# internal (DEFAULT, safe): public ingress-nginx pruned, gateways forced to
#   the nginx-internal class, tier-ingress NetworkPolicy admits only
#   ingress-nginx-internal, host nftables firewall drops inbound 80/443 from
#   outside the tailnet unless /etc/snapdragon/go-live exists.
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
DEFAULT_USER_PASS="snapdragon"
ROOT_PASS="snapdragon"
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
# ── UNAFFILIATED plain desktop (a standalone with ZERO Snapdragon affiliation) ──
# Everything --standalone drops, PLUS: neutral identity strings through the whole
# boot/installer chain (GRUB titles, ISO volids, UKI name, installer text — all
# derived from a forced neutral brand), NO snapdragon-* helper tools/services, NO
# /etc/snapdragon marker tree (the functional home.conf moves to a neutral path),
# NO bundled generator source or brand-repo templates, and NO k8s/mesh package
# payload or config remnants. The result is a plain hardened Gentoo desktop.
# Preset by the `standalone-unaffiliated` role arm; composable onto any client/
# standalone role with --unaffiliated. Brand/branding/seed-code/mesh/SSO flags
# CONFLICT with it (hard error) — unaffiliated means no brand identity at all.
UNAFFILIATED=false      # --unaffiliated : plain Gentoo desktop, no Snapdragon affiliation
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
# --home-seed-code none|repos|stack|mesh : drop the whole Snapdragon source tree +
# a docker-compose runner into ~/snapdragon-stack so the box can run the entire
# stack dockerized (stack) or join an existing tailnet as a dockerized mesh node
# (mesh); 'repos' is just the code. --home-seed-code-from is where to source it
# (a dir like this host's GitHub checkout, or a .tar.* — default: clone at runtime).
HOME_SEED_CODE="none"
HOME_SEED_CODE_FROM=""
# --distdir DIR : reuse a Gentoo distfiles cache from a mounted drive instead of
# re-downloading sources. Empty = auto-detect (top level of /media/*, common
# portage dirs); set explicitly to force one. Speeds rebuilds / enables offline.
DISTDIR_SRC=""
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
# --bundle-source : ship the generator source in the image (/usr/src/snapdragon-
# generator) + a regenerate helper, so you can build a fresh customized ISO from the
# running desktop. Default ON for standalone (self-hosting appliance).
BUNDLE_SOURCE=""
# ── Desktop branding (boot screen / login / wallpaper / colours) ─────────────
# Composable across ALL desktop generations (standalone or tailnet client; cli,
# ncurses or graphical install). A --theme NAME pulls a bundled preset from
# specs-x86/branding/themes/NAME/ (e.g. boogiepop); --branding-dir DIR supplies a
# whole brand dir; the individual --wallpaper/--grub-background/--login-background/
# --brand-logo/--accent-color/--color-scheme flags override single pieces on top.
# Everything is baked by snapdragon-branding at build time and stays user-changeable
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
# remove it (an NM dispatcher re-asserts it). See snapdragon-egress-vpn.
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
# at /media/Steam. All knobs are baked to /etc/snapdragon/media.conf.
MEDIA_DATA=true         # --no-media-data disables the whole feature
MEDIA_MOUNT="/media"    # where the data device mounts
MEDIA_LABEL=""          # --media-label : match the data device by FS LABEL (else content-scan)
MEDIA_MARKERS="Steam Vaults"   # marker dir names that identify the data device by content
STEAM_DIR="/media/Steam"
STEAM_DELIVERY="native"   # --steam : native (DEFAULT; steam-overlay + multilib) | flatpak | none
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
                            (default user). Baked to /etc/snapdragon/identity-role.
  --domains LIST            CLIENT only — domain tie (space/comma separated; first =
                            primary). Baked to /etc/snapdragon/domains + filename tag.
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
      --enable-games        Bake the Snapdragon Game Studio optional service +
                            games.<CLUSTER_DOMAIN> subdomain (OPT-IN; OFF by
                            default). Equivalent to adding 'games' to
                            --optional-services. (env/brand.conf: ENABLE_GAMES=true)
      --optional-services "<slugs>"
                            The SUBSET of user-level OPTIONAL services to bake
                            (allow-list). Choose from akkoma tuwunel phpbb games
                            owncast tube character-studio, or the literal "all"
                            (every user-level slug). Unlisted slugs are pruned from
                            the baked GitOps tree by gate_optional_services.
                            Built-in DEFAULT (no selection) = "akkoma tuwunel phpbb";
                            games/owncast/tube/character-studio are DEFAULT-OFF.
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
                            drops, PLUS no Snapdragon identity anywhere (neutral
                            GRUB titles/ISO volids/UKI/installer text derived
                            from a forced neutral brand), no snapdragon-* tools
                            or /etc/snapdragon markers, no bundled generator
                            source, no k8s/mesh payload. Brand/branding/
                            seed-code/mesh/SSO flags HARD-CONFLICT with it.
                            (role standalone-unaffiliated presets this at the
                            thick/Plasma weight.)
      --capable             Pull the "most capable" Plasma workstation package
                            set (packages-desktop-capable.list). Auto-on for the
                            standalone-thick role.
      --local-user NAME     Standalone local login account (default: ${DEFAULT_USER}).
      --local-pass PASS     Password for the local user. Hashed at build time
                            (yescrypt, $6$ fallback); the plaintext is NEVER baked.
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
      --no-vaults           Don't install gocryptfs / wire /media/Vaults.
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
      --home-seed-code MODE  none|repos|stack|mesh — drop the whole Snapdragon
                            source + a docker-compose runner into ~/snapdragon-stack
                            so the box can run the stack dockerized (stack) or join
                            a tailnet as a dockerized mesh node (mesh).
      --home-seed-code-from PATH  Source the repos from a dir/tar (else clone at runtime).
      --with-tailscale | --no-tailscale   Force the tailnet agent ON/OFF (any role).
      --with-sso | --no-sso               Force the Casdoor/OIDC login ON/OFF (any role).
      --distdir DIR         Reuse a Gentoo distfiles cache from a mounted drive
                            (default: auto-detect /media/*; speeds rebuilds / offline).
      --live-toram | --no-live-toram  Live ISO "Copy to RAM (removable)" boot entry
                            so the stick can be pulled after boot (default ON).
      --installer-ui UI     cli|ncurses|calamares|all — installer front-ends offered
                            as live-ISO boot entries. calamares = graphical Qt
                            installer (Ubuntu-style); standalone defaults to 'all'.
      --cached | --uncached  CACHED embeds the binpkg cache (+distfiles) for offline
                            rebuild / fast reinstall; UNCACHED is lean (default).
      --bundle-source | --no-bundle-source  Ship the generator source +
                            'snapdragon-regenerate' so the desktop can build a fresh
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
# second layer. Legit values (user 'snap', brand 'snapdragon', domain
# 'snapdragon.systems', org 'Snapdragon-Systems', title 'Snapdragon Systems') pass.
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
_validate_org() {        # $1=field-name $2=value ; org name (mixed case, e.g. Snapdragon-Systems)
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
# specs/usr/sbin/snapdragon-branding. Newlines are forbidden by the validators above,
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
        --desktop) DESKTOP="$2"; shift 2 ;;           # thin|full
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
        # Tor v3 onion (hidden) service — a NODE service (DEFAULT-OFF) that exposes the
        # in-cluster fe-gateway as a .onion. Opt-in only; no-op on CLIENT/standalone.
        --with-tor) WANT_TOR=true; shift ;;
        --no-tor) WANT_TOR=false; shift ;;
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
        # ── UNAFFILIATED plain desktop (standalone + zero Snapdragon affiliation) ──
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
# the image only bakes: the /etc/snapdragon/role marker, the OpenRC service set,
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
        ROLE_LABELS="snapdragon.systems/pki=true (+ role=pki via provision.sh)"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-pki" ;;
    be)
        GPU=false; ROLE_K8S="worker"
        ROLE_LABELS="snapdragon.systems/backend=true"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-be" ;;
    fe)
        GPU=false; ROLE_K8S="worker"
        ROLE_LABELS="snapdragon.systems/frontend=true"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-fe" ;;
    be+gpu)
        GPU=true; ROLE_K8S="worker"
        ROLE_LABELS="snapdragon.systems/backend=true,snapdragon.systems/compute=gpu"
        # Keep the legacy 'host' hostname for back-compat with flashers/launchers.
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-host" ;;
    omnibus)
        GPU=true; ROLE_HEADSCALE=true; ROLE_K8S="single-node"
        ROLE_LABELS="snapdragon.systems/pki=true,snapdragon.systems/backend=true,snapdragon.systems/frontend=true,snapdragon.systems/compute=gpu"
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
        ROLE_LABELS="snapdragon.systems/backend=true,snapdragon.systems/compute=gpu,snapdragon.systems/edge-ai=true"
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
        [ "${DESKTOP}" = "thin" ] && DESKTOP="full"   # 'desktop' role defaults to the full/thick weight
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
        STANDALONE=true; DESKTOP="thin"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-standalone-thin" ;;
    standalone-thick|standalone-full)
        GPU=true; ROLE_CLIENT=true; ROLE_K8S="none"; ROLE_HEADSCALE=false
        STANDALONE=true; DESKTOP="full"; CAPABLE=true
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-standalone" ;;
    # ── UNAFFILIATED plain desktop — standalone-thick weight with ZERO Snapdragon
    # affiliation (see the UNAFFILIATED declaration + fold below). The hostname
    # default is assigned in the fold, AFTER the brand identity is neutralized.
    standalone-unaffiliated)
        GPU=true; ROLE_CLIENT=true; ROLE_K8S="none"; ROLE_HEADSCALE=false
        STANDALONE=true; DESKTOP="full"; CAPABLE=true
        UNAFFILIATED=true ;;
    *)
        err "--role must be one of: pki | be | fe | be+gpu | edge_ai | omnibus  (host = be+gpu alias)  |  laptop | chromebook | desktop  |  standalone-thin | standalone-thick | standalone-unaffiliated  (client devices)"
        exit 1 ;;
esac

# ── UNAFFILIATED plain desktop (composable: --unaffiliated onto any client/
# standalone role, or the standalone-unaffiliated role arm above). Runs BEFORE
# the STANDALONE fold so the STANDALONE=true it forces is folded normally.
# Contract: the produced image carries NO Snapdragon (or any other brand)
# affiliation — so every flag that would bake a brand identity, brand assets,
# Snapdragon source, or platform machinery into the image is a HARD CONFLICT,
# not a silent override. What remains: stock Gentoo + the hardened desktop
# stack + the (neutral-named) installer/FDE/home machinery. ──────────────────
if ${UNAFFILIATED}; then
    ${ROLE_CLIENT} || { err "--unaffiliated composes onto desktop/client roles only (got --role ${ROLE} — a cluster node is Snapdragon platform machinery by definition)"; exit 1; }
    STANDALONE=true
    # Brand identity flags conflict (a brand IS an affiliation — including a custom one).
    if [ "${BRAND}" != "snapdragon" ] || [ "${BRAND_TITLE}" != "Snapdragon Systems" ] || [ "${ORG}" != "Snapdragon-Systems" ]; then
        err "--unaffiliated builds carry no brand identity: drop --brand/--brand-title/--org (and any --config brand profile)"; exit 1
    fi
    # Branding-asset flags conflict (nothing to theme against).
    if [ -n "${BRANDING_THEME}" ] || [ -n "${BRANDING_DIR}" ] || [ -n "${BRAND_WALLPAPER}" ] \
       || [ -n "${BRAND_GRUB_BG}" ] || [ -n "${BRAND_GRUB_THEME}" ] || [ -n "${BRAND_LOGIN_BG}" ] \
       || [ -n "${BRAND_LOGO}" ] || [ -n "${BRAND_ACCENT}" ] || [ -n "${BRAND_COLOR_SCHEME}" ] || ${BRAND_LOCKED}; then
        err "--unaffiliated conflicts with branding flags (--theme/--branding-dir/--wallpaper/--grub-background/--grub-theme/--login-background/--brand-logo/--accent-color/--color-scheme/--brand-locked)"; exit 1
    fi
    # Platform-machinery flags conflict: bundled generator source, the dockerized
    # Snapdragon stack seed, the mesh/SSO agents, and person-device identity all
    # tie the image back to the platform.
    [ "${BUNDLE_SOURCE}" = true ] && { err "--unaffiliated conflicts with --bundle-source (bundles the Snapdragon generator source)"; exit 1; }
    [ "${HOME_SEED_CODE}" != none ] && { err "--unaffiliated conflicts with --home-seed-code (seeds the Snapdragon stack into the home)"; exit 1; }
    [ "${MESH_FORCED}" = on ] && { err "--unaffiliated conflicts with --with-tailscale (the tailnet is Snapdragon platform machinery)"; exit 1; }
    [ "${SSO_FORCED}" = on ] && { err "--unaffiliated conflicts with --with-sso (Casdoor SSO is Snapdragon platform machinery)"; exit 1; }
    { [ -n "${PERSON_ROLE}" ] || [ -n "${DOMAINS}" ]; } && { err "--unaffiliated conflicts with --person-role/--domains (person-device identity is platform machinery)"; exit 1; }
    BUNDLE_SOURCE=false
    # Neutral identity: every downstream sink (GRUB titles, ISO volids, UKI name,
    # installer text, artifact filenames, hostname) derives from BRAND/BRAND_TITLE,
    # so forcing them neutral here neutralizes the whole chain.
    BRAND="gentoo"
    BRAND_TITLE="Gentoo Linux"
    ORG="gentoo"
    # Override any BRAND-derived role-default hostname (e.g. 'snapdragon-desktop'
    # from the desktop role arm) — only an explicit -H/--hostname survives.
    ${HOSTNAME_SET} || HOSTNAME="gentoo-desktop"
    # Plain desktop: the Steam/Vaults media-data machinery is Snapdragon-named
    # tooling — default it OFF (an explicit --media-data keeps it, neutral-named).
    [ "${MEDIA_DATA_FORCED}" = on ] || MEDIA_DATA=false
    info "UNAFFILIATED plain desktop: no brand identity, no snapdragon-* tooling, no bundled source, no k8s/mesh payload"
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
# Historically hardcoded SNAPDRAGON_*/snapdragon.* literals;
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
    LIVE_VOLID="SNAPDRAGON_LIVE";   INSTALL_VOLID="SNAPDRAGON_INSTALL"
    UKI_NAME="snapdragon.efi";      INSTALL_CMDLINE_KEY="snapdragon.install"
    ESP_LABEL="SNAP_ESP";           ROOT_LABEL="SNAP_ROOT"
    SB_CERT_O="Snapdragon Systems"; SB_CERT_CN="Snapdragon Secure Boot"
    SB_ETC_DIR="/etc/snapdragon/secureboot"; SB_EFI_VENDOR="snapdragon"
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
${NVIDIA_CUDA} && [ "${GPU_DRIVER}" != "nvidia" ] && { err "--nvidia-cuda requires --gpu-driver nvidia (the proprietary NVIDIA driver)"; exit 1; }
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
[ "${HOME_SEED_CODE}" != none ] && info "Home: seeding the Snapdragon stack code (${HOME_SEED_CODE}) into ~/snapdragon-stack"
# A KEYS USB (--keys-usb DIR) supplies the existing Secure Boot signing key so the
# installed host boots under the key already enrolled in its firmware.
if [ -n "${KEYS_USB}" ]; then
    [ -d "${KEYS_USB}" ] || { err "--keys-usb: directory not found: ${KEYS_USB}"; exit 1; }
    [ -z "${SECUREBOOT_KEY}"  ] && [ -f "${KEYS_USB}/Keys/kernel_key.pem" ] && SECUREBOOT_KEY="${KEYS_USB}/Keys/kernel_key.pem"
    [ -z "${SECUREBOOT_CERT}" ] && [ -f "${KEYS_USB}/Keys/kernel_key.der" ] && SECUREBOOT_CERT="${KEYS_USB}/Keys/kernel_key.der"
    info "KEYS USB: ${KEYS_USB} (Secure Boot key: ${SECUREBOOT_KEY:-<none found>})"
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
# /etc/snapdragon/domains (its first element also feeds a downstream sed replacement).
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

# ── --print-plan: emit the resolved plan and exit BEFORE ANY mutation ──────────
# Runs AFTER full arg parsing / role+GPU+desktop+env validation / the optional-
# services resolution / the standalone posture fold, but BEFORE the run-as-root
# gate directly below (deliberate: planning needs no root), before mkdir, network
# fetches or any sysroot write. One stable KEY=VALUE per line (grep '^PLAN_');
# exit 0. Invalid role/flag combos never reach this point — the validation above
# already exited non-zero, which is exactly what the tests/build-matrix harness
# relies on. SECRETS (--local-pass / --luks-pass / --user-password /
# --root-password values) are NEVER echoed — only a REDACTED presence marker.
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
    _plan JOBS               "${JOBS}"
    _plan BRAND              "${BRAND}"
    _plan CLUSTER_DOMAIN     "${CLUSTER_DOMAIN}"
    _plan SUPERDOMAIN        "${SUPERDOMAIN}"
    _plan HOSTNAME           "${HOSTNAME:-${BRAND}-host}"
    _plan OPTIONAL_SERVICES  "$(${ROLE_CLIENT} && echo none || echo "${OPTIONAL_SERVICES:-none}")"
    _plan MESH               "$(${SKIP_MESH} && echo skip || echo "headscale=${HEADSCALE_VERSION},tailscale=$(${SKIP_TAILSCALE} && echo skip || echo "${TAILSCALE_VERSION}")")"
    _plan SSO                "$(${SKIP_SSO} && echo off || echo casdoor-oidc)"
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
#  'snapdragon-x86-*' / 'snapdragon-*-<role>-*' autodetect globs matching.)
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
    local bl="${sysroot}/etc/modprobe.d/snapdragon-radio-blacklist.conf"
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
# Operates ONLY on ${SYSROOT}/var/lib/snapdragon/cluster/apps — never the repo.
#   prod => prune the LAN wildcard-DNS app (public DNS is authoritative instead).
#   test => prune the go-live cloudflared app (no Cloudflare/ACME on a LAN). The
#           LAN wildcard-DNS app is kept ONLY for a `.test` domain, so it can
#           never become authoritative for a real public domain (e.g. a default
#           ENV=test build still on snapdragon.systems keeps neither edge).
# Pin first-party FLOATING image tags (`:dev`) to the pinned RELEASE_TAG for prod
# so the prod-hygiene gate finds no floating tag, and PRUNE the ENV=test e2e
# harness wave (the test-runner app + its test-only manifests) from the baked
# prod tree. Runs ONLY for ENV=prod (called from gate_env_apps). Conservative sed:
# only first-party image lines (image: ...snapdragon-.../...-{api,ui,bff,web,gateway}:dev
# + the akkoma/tuwunel pins) are rewritten; third-party `:dev`-less images untouched.
rewrite_prod_image_tags() {
    local tree="${SYSROOT}/var/lib/snapdragon/cluster"
    [ -d "${tree}" ] || return 0
    local n=0 f
    while IFS= read -r -d '' f; do
        # Any first-party image (its repo path contains 'snapdragon') tagged :dev
        # -> :RELEASE_TAG. Matches `image: <registry>/snapdragon.../<name>:dev`.
        # The repo-path char class EXCLUDES ':' so the greedy match stops before
        # the ':dev' tag (image repo paths carry no ':' except a registry port,
        # which our first-party images do not use).
        if grep -qE 'image:[[:space:]]*[^[:space:]:]*snapdragon[^[:space:]:]*:dev([[:space:]]|$)' "${f}" 2>/dev/null; then
            sed -i -E "s|(image:[[:space:]]*[^[:space:]:]*snapdragon[^[:space:]:]*):dev|\\1:${RELEASE_TAG}|g" "${f}"
            n=$((n+1))
        fi
    done < <(find "${tree}" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null)
    info "ENV=prod: pinned first-party :dev image tags -> :${RELEASE_TAG} in ${n} file(s)"
    # Prune the ENV=test e2e harness (forbidden in prod by the hygiene gate's
    # tier:test rule). NOTE: the pen-test is now DEV/CI-pipeline-only (a per-repo
    # ArgoCD CI stage + a build option), NOT a deployed cluster wave — there is no
    # pentest-runner app/manifest to prune anymore.
    rm -f "${SYSROOT}/var/lib/snapdragon/cluster/apps/99-test-runner.yaml" \
          "${SYSROOT}/var/lib/snapdragon/cluster/apps/00-app-of-apps-waved.yaml" 2>/dev/null || true
    rm -rf "${SYSROOT}/var/lib/snapdragon/cluster/manifests/test-runner" 2>/dev/null || true
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
# ⚠ CROSS-REPO TODO (gateway wave): CanonicalSeed.java (snapdragon-gateway) bakes
# a route-access floor + the cloudflared configmap hardcodes matrix./mastodon.
# reserved hostnames — keep those in sync with the rows pruned here. NOT edited by
# this build (separate repo / image rebuild).
_opt_selected() {
    # $1 = slug; returns 0 if selected (present in OPTIONAL_SERVICES), else 1.
    local s; for s in ${OPTIONAL_SERVICES}; do [ "${s}" = "$1" ] && return 0; done
    return 1
}
gate_optional_services() {
    local tree="${SYSROOT}/var/lib/snapdragon/cluster"
    local apps="${tree}/apps"
    [ -d "${apps}" ] || return 0
    local slug
    for slug in akkoma tuwunel phpbb games owncast tube character-studio headwind attestation-server egress-vpn workloadConsole edge-ai edge-ai-analysis edge-ai-tts tor; do
        _opt_selected "${slug}" && continue
        info "OPTIONAL_SERVICES: '${slug}' NOT selected — pruning it from the baked tree"
        case "${slug}" in
            akkoma)
                rm -f "${apps}/30-akkoma.yaml"
                rm -rf "${tree}/manifests/akkoma"
                rm -f "${tree}/manifests/external-secrets/akkoma-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" akkoma-externalsecrets.yaml
                _opt_drop_route "${apps}/20-gateway-be.yaml" mastodon-oauth mastodon-api mastodon-web
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/api/v1/pleroma/admin/**' '/api/pleroma/admin/**' '/pleroma/admin/**'
                ;;
            tuwunel)
                rm -f "${apps}/30-tuwunel.yaml"
                rm -rf "${tree}/manifests/tuwunel"
                rm -f "${tree}/manifests/external-secrets/tuwunel-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" tuwunel-externalsecrets.yaml
                _opt_drop_route "${apps}/20-gateway-be.yaml" matrix-api matrix-wellknown matrix
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/_matrix/**' '/.well-known/matrix/**' '/_synapse/**'
                ;;
            phpbb)
                rm -f "${apps}/30-phpbb.yaml" "${apps}/38-forum-bff-db.yaml" \
                      "${apps}/39-forum-bff-api.yaml" "${apps}/49-forum-ui.yaml"
                rm -rf "${tree}/manifests/forum"
                _opt_drop_route "${apps}/20-gateway-fe.yaml" forum-ui snapdragon-forum-bff-api snapdragon-forum-bff-api-moderation
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-fe-gateway \
                    '/social/forum/**' '/bff/forum/admin/**' '/bff/forum/moderation/**' '/bff/forum/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/api/forum/admin/**'
                ;;
            games)
                rm -f "${apps}/06-casdoor-games.yaml" "${apps}/50-games.yaml"
                rm -rf "${tree}/manifests/games" "${tree}/manifests/casdoor-games"
                _opt_drop_route     "${apps}/20-gateway-be.yaml" games
                _opt_drop_extrahost "${apps}/20-gateway-be.yaml" games.
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/games/api/admin/**' '/games/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-fe-gateway \
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
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/bff/superadmin/games-services/**' '/bff/games-services/instances/**' \
                    '/bff/games-services/catalog/**' '/games/servers/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-fe-gateway \
                    '/admin/games-services/**'
                ;;
            edge-ai)
                rm -f "${apps}/54-edge-ai.yaml"
                rm -rf "${tree}/manifests/edge-ai"
                _opt_drop_route "${apps}/20-gateway-be.yaml" edge-ai
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/v1/**'
                ;;
            edge-ai-analysis)
                rm -f "${apps}/55-edge-ai-analysis.yaml"
                rm -rf "${tree}/manifests/edge-ai-analysis"
                _opt_drop_route "${apps}/20-gateway-be.yaml" edge-ai-analysis
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
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
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/v1/synthesize/**'
                ;;
            owncast)
                # Owncast live-streaming — GPU-gated x86 service (DEFAULT-OFF). Owns its
                # bootstrap Application + manifests dir + its fe-gateway BFF route-access
                # rows (no gateway HOST route + no per-service ESO today). When deselected
                # the user/admin live-stream panels grey out (installed-services "false").
                rm -f "${apps}/52-owncast.yaml"
                rm -rf "${tree}/manifests/owncast"
                _opt_drop_route "${apps}/20-gateway-fe.yaml" snapdragon-owncast-bff-api
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-fe-gateway \
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
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-fe-gateway \
                    '/character-studio/**'
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
                _opt_drop_route "${apps}/20-gateway-fe.yaml" snapdragon-tube-bff-api tube-content
                _opt_drop_route "${apps}/20-gateway-be.yaml" tube-content
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-fe-gateway \
                    '/bff/tube/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
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
                ;;
            workloadConsole)
                # The WORKLOAD CONSOLE is RBAC + route-access ONLY (the BFF endpoints live in
                # the always-present admin-bff). Deselecting it prunes the two-SA RBAC
                # Application + its manifests (so the SA tokens are never minted) AND the two
                # route-access rows, so the gateway 404s the whole /bff/{admin,superadmin}/
                # workloads/** prefix. The admin-bff ALSO ships dark independently
                # (app.workload-console.enabled=false), so even an un-pruned tree is inert.
                rm -f "${apps}/14-workload-console-rbac.yaml"
                rm -rf "${tree}/manifests/workload-console-rbac"
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/bff/superadmin/workloads/**' '/bff/admin/workloads/**'
                ;;
            headwind)
                # Headwind MDM (Enterprise Phones) — DEFAULT-OFF, admin-only devops
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
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-superadmin-gateway \
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
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-superadmin-gateway \
                    '/attest/auditor/**' '/attest/api/status' '/attest/api/**'
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
                    # a comment ABOVE the next sibling can attach; stop skipping
                    # once we reach a line at or below the captured item indent
                    # that begins a new list item or a shallower key.
                    if (line ~ /^ *- id:/ && cur<=ind) { skip=0 }
                    else if (line !~ /^ *$/ && cur<=ind && line !~ /^ *#/) { skip=0 }
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
    local cm="${SYSROOT}/var/lib/snapdragon/cluster/manifests/policy/installed-services-configmap.yaml"
    [ -f "${cm}" ] || return 0
    local slug val
    for slug in akkoma tuwunel phpbb games owncast tube character-studio headwind attestation-server workloadConsole edge-ai edge-ai-analysis edge-ai-tts; do
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
    local seed="${SYSROOT}/var/lib/snapdragon/cluster/manifests/optional-services-operator/seed-optionalservices.yaml"
    [ -f "${seed}" ] || return 0
    local slug val
    for slug in akkoma tuwunel phpbb games owncast tube character-studio edge-ai edge-ai-analysis edge-ai-tts; do
        if _opt_selected "${slug}"; then val="true"; else val="false"; fi
        _opt_set_cr_enabled "${seed}" "${slug}" "${val}"
    done
    info "OPTIONAL_SERVICES: seeded OptionalService CR enabled flags (selected: ${OPTIONAL_SERVICES:-none})"
}
# Parameterize the games-realm OIDC identity on GAMES_DOMAIN. rebrand_sysroot does
# NOT touch the .games literals (its rules match snapdragon.systems / snapdragon-),
# so the games host + issuer + redirects would otherwise stay snapdragon.games and
# break iss-strict JWT validation under the subdomain default. Runs UNCONDITIONALLY
# (even for the default brand) and BEFORE rebrand_sysroot so the default literal
# games.snapdragon.systems composes with the snapdragon.systems->CLUSTER_DOMAIN
# rule. A custom GAMES_DOMAIN (e.g. <brand>.games) is rebrand-neutral.
parameterize_games_domain() {
    local tree="${SYSROOT}/var/lib/snapdragon/cluster"
    [ -d "${tree}" ] || return 0
    local f n=0
    # GAMES_DOMAIN is allowlisted ([a-z0-9.-]) at parse; escape it against the sed
    # replacement metacharacters (\ & |) for defense-in-depth — matching how every other
    # rendered field is handled, so this stays injection-proof if the validator is ever
    # loosened. (The '#'-delimited sink below is also safe: the allowlist excludes '#'.)
    local gd_e; gd_e="$(_sed_rep_escape "${GAMES_DOMAIN}")"
    # URL-SCHEME-ANCHORED: only rewrite snapdragon.games when it is a HOST (right
    # after the // of https://...), so the games-realm origin/issuer/redirect/website
    # URLs flip to ${GAMES_DOMAIN} while the canonical IMAGE repo paths
    # (snapdragon-systems/snapdragon.games-backend, .../snapdragon.games/backend) are
    # left untouched. id.snapdragon.games -> id.${GAMES_DOMAIN}; bare host -> ${GAMES_DOMAIN}.
    while IFS= read -r -d '' f; do
        if grep -q '//id\.snapdragon\.games\|//snapdragon\.games' "${f}" 2>/dev/null; then
            sed -i -E \
                -e "s|//id\\.snapdragon\\.games|//id.${gd_e}|g" \
                -e "s|//snapdragon\\.games|//${gd_e}|g" \
                "${f}"
            n=$((n+1))
        fi
    done < <(find "${tree}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.sql' \) -print0 2>/dev/null)
    info "Games domain: parameterized games host URLs -> ${GAMES_DOMAIN} in ${n} file(s)"
    # The games PUBLIC host literal (gateway-be route host + ingress extraHost) is
    # "games.snapdragon.systems" so it composes with the snapdragon.systems ->
    # CLUSTER_DOMAIN rebrand into games.<CLUSTER_DOMAIN> = the DEFAULT GAMES_DOMAIN.
    # If the operator set a CUSTOM GAMES_DOMAIN (e.g. the real <brand>.games TLD),
    # the host must follow it instead of the subdomain default — rewrite it here,
    # BEFORE rebrand (which would otherwise only map the snapdragon.systems suffix).
    if [ "${GAMES_DOMAIN}" != "games.snapdragon.systems" ]; then
        local be="${tree}/apps/20-gateway-be.yaml"
        [ -f "${be}" ] && sed -i -E "s#games\\.snapdragon\\.systems#${gd_e}#g" "${be}"
        info "Games domain: custom GAMES_DOMAIN — games host rewritten to ${GAMES_DOMAIN}"
    fi
}

gate_env_apps() {
    local apps="${SYSROOT}/var/lib/snapdragon/cluster/apps"
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
        local cluster="${SYSROOT}/var/lib/snapdragon/cluster"
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
# bakes /etc/snapdragon/release-state, parallel to the existing
# /etc/snapdragon/cluster-domain bake below. The FIRST-EVER ruleset load
# happens at first boot (the oneshot), rendered from this baked value + the
# (absent-by-default) go-live marker, so there is no separate build-time
# nftables.conf to keep in sync.
bake_host_firewall() {
    mkdir -p "${SYSROOT}/usr/sbin" "${SYSROOT}/usr/lib/snapdragon" "${SYSROOT}/etc/init.d" "${SYSROOT}/etc/cron.d" "${SYSROOT}/etc/snapdragon"
    cp "${SHARED_SPECS}/usr/sbin/snapdragon-firewall-reconcile"   "${SYSROOT}/usr/sbin/snapdragon-firewall-reconcile"
    chmod +x "${SYSROOT}/usr/sbin/snapdragon-firewall-reconcile"
    cp "${SHARED_SPECS}/etc/init.d/snapdragon-firewall-reconcile" "${SYSROOT}/etc/init.d/snapdragon-firewall-reconcile"
    chmod +x "${SYSROOT}/etc/init.d/snapdragon-firewall-reconcile"
    cp "${SHARED_SPECS}/etc/cron.d/snapdragon-firewall-reconcile" "${SYSROOT}/etc/cron.d/snapdragon-firewall-reconcile"
    # ── Go-Live wizard: the human-facing effector of this same firewall-reconcile /
    #    release-state mechanism (driver writes /etc/snapdragon/go-live; reconcile
    #    converges <=60s). Baked unconditionally alongside reconcile — inert until the
    #    marker is written. Front-ends: -cli (thin CLI) and -menu (thin ncurses console).
    cp "${SHARED_SPECS}/usr/sbin/snapdragon-go-live"              "${SYSROOT}/usr/sbin/snapdragon-go-live"
    chmod +x "${SYSROOT}/usr/sbin/snapdragon-go-live"
    cp "${SHARED_SPECS}/usr/sbin/snapdragon-go-live-cli"          "${SYSROOT}/usr/sbin/snapdragon-go-live-cli"
    chmod +x "${SYSROOT}/usr/sbin/snapdragon-go-live-cli"
    cp "${SHARED_SPECS}/usr/sbin/snapdragon-go-live-menu"         "${SYSROOT}/usr/sbin/snapdragon-go-live-menu"
    chmod +x "${SYSROOT}/usr/sbin/snapdragon-go-live-menu"
    cp "${SHARED_SPECS}/usr/lib/snapdragon/go-live-providers.sh"  "${SYSROOT}/usr/lib/snapdragon/go-live-providers.sh"
    echo "${RELEASE_STATE:-internal}" > "${SYSROOT}/etc/snapdragon/release-state"
    # ── Go-Live web-UI effector: the 4th front-end (admin-bff's web console) can only
    #    RECORD a signed intent (it runs in a pod, can't touch this host's filesystem);
    #    this agent is what actually drives the SAME driver's commit/rollback for a
    #    web-originated intent. Baked alongside the driver it depends on (harmlessly
    #    inert without it — same fail-closed gate as every reconcile agent: missing
    #    verify lib / node.env / baked pubkey -> keep cache, exit 0, apply nothing).
    cp "${SHARED_SPECS}/usr/sbin/snapdragon-go-live-reconcile"     "${SYSROOT}/usr/sbin/snapdragon-go-live-reconcile"
    chmod +x "${SYSROOT}/usr/sbin/snapdragon-go-live-reconcile"
    cp "${SHARED_SPECS}/usr/lib/snapdragon/golive-verify.sh"       "${SYSROOT}/usr/lib/snapdragon/golive-verify.sh"
    cp "${SHARED_SPECS}/etc/init.d/snapdragon-go-live-reconcile"   "${SYSROOT}/etc/init.d/snapdragon-go-live-reconcile"
    chmod +x "${SYSROOT}/etc/init.d/snapdragon-go-live-reconcile"
    cp "${SHARED_SPECS}/etc/cron.d/snapdragon-go-live-reconcile"   "${SYSROOT}/etc/cron.d/snapdragon-go-live-reconcile"
    info "RELEASE_STATE=${RELEASE_STATE:-internal}: baked the host nftables backstop (snapdragon-firewall-reconcile renders + loads the live ruleset at boot + every 60s) + the go-live wizard (driver/registry/CLI/ncurses front-ends) + the web-UI go-live effector (snapdragon-go-live-reconcile)"
}

# Rebrand the baked cluster tree (no-op for default snapdragon naming).
rebrand_sysroot() {
    if [ "${BRAND}" = "snapdragon" ] && [ "${CLUSTER_DOMAIN}" = "snapdragon.systems" ] \
       && [ "${ORG}" = "Snapdragon-Systems" ] && [ "${BRAND_TITLE}" = "Snapdragon Systems" ]; then
        info "Branding: default (snapdragon) — no rebrand"; return 0
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
        # FROZEN k8s label-KEY / API-group namespace `snapdragon.systems/<suffix>` must NOT
        # rebrand (it is compiled into operators/JVM and used as node/pod selectors). Every
        # KEY form is preceded by a YAML-structural boundary (line-start, space, {, (, comma,
        # quote, backtick); every HOST/URL form is preceded by a dot or slash. Protect the KEY
        # namespace behind a sentinel (first two -e), rebrand hosts/URLs/emails/CORS in the
        # middle, then restore the KEY namespace verbatim (last -e). The sentinel contains
        # neither `snapdragon.systems` nor `snapdragon-`, so the middle rules skip it.
        sed -i \
            -e "s|^snapdragon\.systems/|@@SDSYSKEY@@/|g" \
            -e "s|\([ {(,\"'\`]\)snapdragon\.systems/|\1@@SDSYSKEY@@/|g" \
            -e "s|Snapdragon Systems|${_btitle}|g" \
            -e "s|snapdragon-systems/|${_orglc}/|g" \
            -e "s|Snapdragon-Systems|${_org}|g" \
            -e "s|//id\.snapdragon\.games|//id.${_games}|g" \
            -e "s|//snapdragon\.games|//${_games}|g" \
            -e "s|snapdragon\.systems|${_domain}|g" \
            -e "s|\(registry\.[A-Za-z0-9.-]*\)/snapdragon/|\1/${_hproj}/|g" \
            -e "s|snapdragon-|${_brand}-|g" \
            -e "s|@@SDSYSKEY@@/|snapdragon.systems/|g" \
            "${f}"
    done < <(find "${SYSROOT}/var/lib/snapdragon/cluster" "${SYSROOT}/etc/snapdragon" -type f -print0 2>/dev/null)
}

# ── 0. Prereqs ─────────────────────────────────────────────────────
banner "Verifying prerequisites"
[ -d "${SPECS_DIR}" ]   || { err "Missing ${SPECS_DIR}"; exit 1; }
[ -d "${SHARED_SPECS}" ] || { err "Missing ${SHARED_SPECS}"; exit 1; }
for t in curl tar file; do command -v "$t" >/dev/null || { err "missing tool: $t"; exit 1; }; done
# .img builder tools (default deliverable) — losetup/mkfs/parted/grub-mkimage must
# be present and the build must run as root (already enforced). grub-mkimage must
# support the x86_64-efi target for the GRUB-EFI removable install.
if ${BUILD_IMG}; then
    for t in parted losetup mkfs.vfat mkfs.ext4 blkid grub-mkimage; do
        command -v "$t" >/dev/null || { warn "missing ${t}; disabling .img build"; BUILD_IMG=false; break; }
    done
    if ${BUILD_IMG} && [ ! -d /usr/lib/grub/x86_64-efi ]; then
        warn "grub x86_64-efi target not found (/usr/lib/grub/x86_64-efi); .img will not be UEFI-bootable"
        warn "rebuild sys-boot/grub with GRUB_PLATFORMS containing efi-64"
    fi
fi
if ${LIVE_ISO}; then
    for t in grub-mkrescue xorriso; do
        command -v "$t" >/dev/null || { warn "missing ${t}; disabling --live-iso"; LIVE_ISO=false; break; }
    done
    # Either mksquashfs (sys-fs/squashfs-tools) or tar2sqfs (sys-fs/squashfs-tools-ng)
    # can squash the rootfs; the squash step below picks whichever is present.
    if ${LIVE_ISO} && ! command -v mksquashfs >/dev/null && ! command -v tar2sqfs >/dev/null; then
        warn "missing mksquashfs AND tar2sqfs; disabling --live-iso"; LIVE_ISO=false
    fi
fi
if ${INSTALLER_ISO}; then
    command -v xorriso >/dev/null || warn "no xorriso; installer ISO will be left as a plain tree"
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

# ── 1. Directories ─────────────────────────────────────────────────
banner "Preparing build directories"
mkdir -p "${WORK_DIR}" "${BUILD_ROOT}"/{distfiles,pkgdir} "${SYSROOT}" "${ISO_DIR}"
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
banner "Fetching amd64 hardened stage3 seed"
# The index is PGP-signed; select the stage3 tarball line, ignoring armor/comments.
STAGE3_FILE=$(curl -sL --retry 5 --retry-delay 5 --retry-connrefused --retry-all-errors "${SEED_STAGE3_URL}" | awk '/stage3-.*\.tar\.xz/{print $1; exit}')
# Per-arch: the amd64 seed must not be reused by (or clobber) the aarch64 build.
STAGE3_LOCAL="${BUILD_ROOT}/$(basename "${STAGE3_FILE}")"
STAGE3_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_FILE}"
[ -f "${STAGE3_LOCAL}" ] || { info "Downloading $(basename "${STAGE3_FILE}")"; curl -fL --retry 5 --retry-delay 5 --retry-connrefused --retry-all-errors -o "${STAGE3_LOCAL}" "${STAGE3_URL}"; }

# SUPPLY-CHAIN: verify the seed's integrity+authenticity before we trust a single
# byte of it. dlv_verify_stage3 fetches the matching .DIGESTS(.asc), GPG-verifies
# it against the pinned Gentoo release-engineering key, then checks the tarball's
# SHA512/SHA256 against the signed DIGESTS — ABORTING on any signature/checksum
# mismatch. A poisoned mirror or MITM can no longer slip a backdoored seed in.
# (Mirrors the rpi5/frite/jetson builders; the amd64 seed was the last unverified one.)
banner "Verifying stage3 seed signature + checksum"
if ! dlv_verify_stage3 "${STAGE3_LOCAL}" "${STAGE3_URL}.DIGESTS"; then
    rm -f "${STAGE3_LOCAL}"   # drop the unverified file so a re-run re-fetches
    err "stage3 seed failed verification (bad signature or checksum) — aborting."
    err "If Gentoo rotated its signing key, set DLV_GENTOO_KEY=<fingerprint>; for an"
    err "air-gapped build set DLV_OFFLINE_KEYRING=<keyfile>. Refusing unverified seed."
    exit 1
fi

# ── 3. Extract ─────────────────────────────────────────────────────
banner "Extracting stage3"
if [ -f "${SYSROOT}/etc/gentoo-release" ] && ${RESUME}; then
    info "Sysroot populated and --resume — skipping extraction"
else
    # A non-resume build must start from a CLEAN sysroot. Extracting stage3 OVER a
    # populated tree leaves stale packages (e.g. extra python slots, old kubelet)
    # in var/db/pkg — a HYBRID db that breaks dep resolution (observed: 3 python
    # slots surviving + libselinux[python] conflicts). Wipe first so the extract
    # is pristine. (Warm reuse is the explicit --resume path above.)
    if [ -f "${SYSROOT}/etc/gentoo-release" ]; then
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
banner "Installing spec files"
mkdir -p "${SYSROOT}/etc/portage/"{package.use,package.accept_keywords,package.license,package.mask,profile,env}
render_template "${SPECS_DIR}/portage/make.conf.tmpl" "${SYSROOT}/etc/portage/make.conf"
# Native Steam is a 32-bit app: enable the multilib ABI so its deps build with
# ABI_X86_32 (the amd64-hardened stage3 seed is multilib-capable). Scoped to the
# native-Steam gaming desktops; every other image stays pure 64-bit.
if ${STEAM_NATIVE}; then
    printf '\n# Native Steam (32-bit runtime) — see package.use/steam\nABI_X86="64 32"\n' >> "${SYSROOT}/etc/portage/make.conf"
    info "Native Steam: ABI_X86=\"64 32\" (multilib) added to make.conf"
fi
cp "${SPECS_DIR}/portage/profile/parent"              "${SYSROOT}/etc/portage/profile/parent"
# Copy every file in these portage config dirs (so added spec files always land).
# The 'desktop' files (LXDE ~amd64 keywords / GTK+netsurf USE) are client-only — a
# k8s NODE image stays stable-keyworded and never references desktop USE flags. The
# 'nvidia' files are copied ONLY for the proprietary GPU stack; 'capable' ONLY for
# the most-capable Plasma set (--capable / standalone-thick).
for akf in "${SPECS_DIR}/portage/package.accept_keywords/"*; do
    [ -e "${akf}" ] || continue
    case "$(basename "${akf}")" in
        desktop) ${ROLE_CLIENT} || continue ;;
        capable) ${CAPABLE} || continue ;;
        nvidia)  ${NVIDIA_PROPRIETARY} || continue ;;
        amd-pro) ${AMD_PRO} || continue ;;
        intel-pro) ${INTEL_PRO} || continue ;;
        steam)   ${STEAM_NATIVE} || continue ;;
        home-encrypted) ${HOME_ENCRYPTED} || continue ;;
        seed-code)      ${WANT_DOCKER}    || continue ;;
        calamares)      ${WANT_CALAMARES} || continue ;;
    esac
    cp "${akf}" "${SYSROOT}/etc/portage/package.accept_keywords/"
done
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
        amd-pro) ${AMD_PRO} || continue ;;
        intel-pro) ${INTEL_PRO} || continue ;;
        steam)   ${STEAM_NATIVE} || continue ;;
    esac
    cp "${puf}" "${SYSROOT}/etc/portage/package.use/"
done
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
    printf '# Snapdragon: proprietary NVIDIA driver owns the GPU; keep nouveau out.\nblacklist nouveau\noptions nouveau modeset=0\n' \
        > "${SYSROOT}/etc/modprobe.d/snapdragon-nvidia.conf"
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
    mkdir -p "${SYSROOT}/etc/portage/env"
    cp -r "${SPECS_DIR}/portage/env/"* "${SYSROOT}/etc/portage/env/" 2>/dev/null || true
fi
[ -f "${SPECS_DIR}/portage/package.env" ] && \
    cp "${SPECS_DIR}/portage/package.env" "${SYSROOT}/etc/portage/package.env"

# x86 GRUB cmdline (SELinux LSM + KSPP hardening). Disable os-prober so a
# grub-mkconfig (installer / chroot) can never enumerate the host's other disks.
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
if [ -f "${SPECS_DIR}/etc/dracut.conf.d/60-snapdragon-crypt.conf" ]; then
    mkdir -p "${SYSROOT}/etc/dracut.conf.d"
    if ${UNAFFILIATED}; then
        cp "${SPECS_DIR}/etc/dracut.conf.d/60-snapdragon-crypt.conf" "${SYSROOT}/etc/dracut.conf.d/60-crypt.conf"
    else
        cp "${SPECS_DIR}/etc/dracut.conf.d/60-snapdragon-crypt.conf" "${SYSROOT}/etc/dracut.conf.d/"
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

# ── NVIDIA GPU runtime (snapdragon edge-AI / GPU workloads) ──────────────────
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
# (NO any-to-any tag:snapdragon->tag:snapdragon:* :22 hole; KEEPS the k8s CIDR
# data-plane rule + a single conservative @@TS_SSH_USER@@ ssh rule). The #66
# full-mesh policy.hujson is intentionally NOT baked here — its any-to-any :22 hole
# must not exist at any time. The first verified Layer-A sync wholesale re-renders
# this from policy.hujson.tmpl. (provision_headscale also restages this from
# policy.bootstrap.hujson at provision time as a belt-and-braces.)
cp "${SHARED_SPECS}/etc/headscale/policy.bootstrap.hujson" "${SYSROOT}/etc/headscale/policy.hujson"   # Layer-A bootstrap (policy.mode: file)
cp "${SHARED_SPECS}/etc/keys-provision/provision.sh"  "${SYSROOT}/usr/sbin/keys-provision"; chmod +x "${SYSROOT}/usr/sbin/keys-provision"
mkdir -p "${SYSROOT}/usr/local/sbin"
cp "${SHARED_SPECS}/usr/local/sbin/snapdragon-backup"  "${SYSROOT}/usr/local/sbin/snapdragon-backup"; chmod +x "${SYSROOT}/usr/local/sbin/snapdragon-backup"
fi   # ! UNAFFILIATED (headscale/keys-provision/backup platform tools)
# UNAFFILIATED keeps only growroot (first-boot .img root expansion — generic).
if ${UNAFFILIATED}; then _base_svcs="growroot"; else _base_svcs="containerd kubelet headscale tailscaled keys-provision growroot"; fi
for svc in ${_base_svcs}; do
    cp "${SHARED_SPECS}/etc/init.d/${svc}" "${SYSROOT}/etc/init.d/${svc}"; chmod +x "${SYSROOT}/etc/init.d/${svc}"
done
unset _base_svcs
# firewalld installs /etc/init.d/firewalld; alias 'firewall' so the `after firewall`
# deps in tailscaled/kubelet/headscale/containerd/egress-vpn still resolve.
ln -sfn firewalld "${SYSROOT}/etc/init.d/firewall"
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
# /etc/snapdragon/registry (installed on ADMIN nodes only; conf gate-flips on first
# verified sync).
# UNAFFILIATED skips this whole platform block (Layer-B/Layer-A registries, the
# domain-registry bridge, tor reconcile, and the brand-repo generator bundle) —
# all of it is Snapdragon mesh/fleet machinery with no place on a plain desktop.
if ! ${UNAFFILIATED}; then
mkdir -p "${SYSROOT}/usr/lib/snapdragon" "${SYSROOT}/etc/snapdragon/registry" "${SYSROOT}/var/lib/snapdragon/device-registry"
cp "${SHARED_SPECS}/usr/sbin/snapdragon-authorized-keys-lookup" "${SYSROOT}/usr/sbin/snapdragon-authorized-keys-lookup"; chmod +x "${SYSROOT}/usr/sbin/snapdragon-authorized-keys-lookup"
cp "${SHARED_SPECS}/usr/sbin/snapdragon-device-registry-sync"   "${SYSROOT}/usr/sbin/snapdragon-device-registry-sync";   chmod +x "${SYSROOT}/usr/sbin/snapdragon-device-registry-sync"
cp "${SHARED_SPECS}/usr/lib/snapdragon/registry-verify.sh"      "${SYSROOT}/usr/lib/snapdragon/registry-verify.sh"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-device-registry-sync" "${SYSROOT}/etc/init.d/snapdragon-device-registry-sync"; chmod +x "${SYSROOT}/etc/init.d/snapdragon-device-registry-sync"
cp "${SHARED_SPECS}/etc/ssh/sshd_config.d/device-registry.conf" "${SYSROOT}/etc/snapdragon/registry/device-registry.conf"
cp "${SHARED_SPECS}/etc/ssh/sshd_config.d/break-glass.conf"     "${SYSROOT}/etc/snapdragon/registry/break-glass.conf"
cp "${SHARED_SPECS}/etc/cron.d/snapdragon-device-registry-sync" "${SYSROOT}/etc/snapdragon/registry/cron-device-registry-sync"

# ── Layer-A device-license-registry headscale policy (CONTROL/pki node only) ────
# CENTRALIZED: provision_headscale_policy_sync() ACTIVATES these only when
# headscale.enabled==true (the control node). The renderer + forced-tag pass + the
# bootstrap policy + the render template are baked into every host image (inert on
# a non-control node); REUSES the SAME registry-verify.sh + baked
# registry-pub.ed25519 as Layer-B (no duplication).
cp "${SHARED_SPECS}/usr/sbin/gen-headscale-policy.sh"          "${SYSROOT}/usr/sbin/gen-headscale-policy.sh";          chmod +x "${SYSROOT}/usr/sbin/gen-headscale-policy.sh"
cp "${SHARED_SPECS}/usr/sbin/snapdragon-headscale-forcetags"   "${SYSROOT}/usr/sbin/snapdragon-headscale-forcetags";   chmod +x "${SYSROOT}/usr/sbin/snapdragon-headscale-forcetags"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-policy-sync"         "${SYSROOT}/etc/init.d/snapdragon-policy-sync";         chmod +x "${SYSROOT}/etc/init.d/snapdragon-policy-sync"
cp "${SHARED_SPECS}/etc/headscale/policy.bootstrap.hujson"     "${SYSROOT}/etc/headscale/policy.bootstrap.hujson"
cp "${SHARED_SPECS}/etc/headscale/policy.hujson.tmpl"          "${SYSROOT}/etc/headscale/policy.hujson.tmpl"
cp "${SHARED_SPECS}/etc/cron.d/snapdragon-policy-sync"         "${SYSROOT}/etc/snapdragon/registry/cron-policy-sync"

# ── Domain-registry -> brand-repo bridge (#4) — DEFAULT-OFF optional service ─────
# Bake the reconcile agent + its source-and-extend verify lib (domain-verify.sh) +
# the OpenRC service into every host image. INERT until enabled (the gate below
# links the service + cron ONLY when `domain-registry-bridge` is selected; a real
# key is required to verify; absent transport it keeps cache + emits nothing).
# REUSES the baked registry-pub.ed25519 (Layer-B's key — never re-bake). The agent
# drives the EXISTING gen-keystores.sh + generate-brand-repos.sh, so those two
# generators + the templates are baked under /usr/share/snapdragon/generator.
cp "${SHARED_SPECS}/usr/sbin/snapdragon-domain-reconcile"      "${SYSROOT}/usr/sbin/snapdragon-domain-reconcile";      chmod +x "${SYSROOT}/usr/sbin/snapdragon-domain-reconcile"
cp "${SHARED_SPECS}/usr/lib/snapdragon/domain-verify.sh"       "${SYSROOT}/usr/lib/snapdragon/domain-verify.sh"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-domain-reconcile"    "${SYSROOT}/etc/init.d/snapdragon-domain-reconcile";    chmod +x "${SYSROOT}/etc/init.d/snapdragon-domain-reconcile"
cp "${SHARED_SPECS}/etc/cron.d/snapdragon-domain-reconcile"    "${SYSROOT}/etc/snapdragon/registry/cron-domain-reconcile"

# ── Tor v3 onion (hidden) service (#tor) — DEFAULT-OFF NODE service ──────────────
# Bake the onion-service reconcile agent + its OpenRC oneshot + the 24h cron into every
# host image (INERT until enabled). The DISTRO Tor daemon (net-vpn/tor → /etc/init.d/tor
# + /etc/tor/torrc) is installed + linked ONLY when 'tor' is selected (the SVCS/PKGS
# gates below); this agent (ordered `before tor`) writes the managed torrc and mints +
# persists the v3 onion keypair OFF-GIT under /var/lib/tor/snapdragon-onion on first boot.
cp "${SHARED_SPECS}/usr/sbin/snapdragon-tor-reconcile"        "${SYSROOT}/usr/sbin/snapdragon-tor-reconcile";        chmod +x "${SYSROOT}/usr/sbin/snapdragon-tor-reconcile"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-tor-reconcile"      "${SYSROOT}/etc/init.d/snapdragon-tor-reconcile";      chmod +x "${SYSROOT}/etc/init.d/snapdragon-tor-reconcile"
cp "${SHARED_SPECS}/etc/cron.d/snapdragon-tor-reconcile"      "${SYSROOT}/etc/snapdragon/registry/cron-tor-reconcile"
mkdir -p "${SYSROOT}/usr/share/snapdragon/generator/scripts" "${SYSROOT}/usr/share/snapdragon/generator/templates"
cp "${SCRIPT_DIR}/scripts/gen-keystores.sh"  "${SYSROOT}/usr/share/snapdragon/generator/scripts/gen-keystores.sh";  chmod +x "${SYSROOT}/usr/share/snapdragon/generator/scripts/gen-keystores.sh"
cp "${SCRIPT_DIR}/generate-brand-repos.sh"   "${SYSROOT}/usr/share/snapdragon/generator/generate-brand-repos.sh";   chmod +x "${SYSROOT}/usr/share/snapdragon/generator/generate-brand-repos.sh"
cp -r "${SCRIPT_DIR}/templates/."            "${SYSROOT}/usr/share/snapdragon/generator/templates/"
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
# by this build. Consumed by snapdragon-home-setup (runs at first boot, after the
# 01-firstboot user is created) and read by the installer for adopt/restore.
# UNAFFILIATED: same functional machinery under NEUTRAL names — the conf moves to
# /etc/gentoo/home.conf, the helper installs as /usr/sbin/home-setup, and its
# internal snapdragon-* literals (conf path, first-login-encrypt dotfile) are
# rewritten on the staged copy. install-x86.sh's staged copy gets the matching
# conf-path rewrite where the installer ISO is built (below).
if ${UNAFFILIATED}; then
    HOME_CONF_DIR="/etc/gentoo"; HOME_SETUP_NAME="home-setup"
else
    HOME_CONF_DIR="/etc/snapdragon"; HOME_SETUP_NAME="snapdragon-home-setup"
fi
mkdir -p "${SYSROOT}${HOME_CONF_DIR}"
# home.conf is dot-sourced as ROOT at first boot (snapdragon-home-setup) AND by the
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
if [ -f "${SHARED_SPECS}/usr/sbin/snapdragon-home-setup" ]; then
    cp "${SHARED_SPECS}/usr/sbin/snapdragon-home-setup" "${SYSROOT}/usr/sbin/${HOME_SETUP_NAME}"
    chmod +x "${SYSROOT}/usr/sbin/${HOME_SETUP_NAME}"
    if ${UNAFFILIATED}; then
        # Neutralize the staged copy's internal literals (fail loudly on drift).
        grep -q '^CONF=/etc/snapdragon/home.conf' "${SYSROOT}/usr/sbin/${HOME_SETUP_NAME}" \
            || { err "snapdragon-home-setup drifted: CONF= line not found (unaffiliated rename would break silently)"; exit 1; }
        sed -i -e "s|/etc/snapdragon/home.conf|${HOME_CONF_DIR}/home.conf|g" \
               -e 's/snapdragon-home-setup/home-setup/g' \
               -e 's/snapdragon-first-login-encrypt/first-login-encrypt/g' \
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
# helper to drop into ~/snapdragon-stack at first boot.
if [ "${HOME_SEED_CODE}" != none ] && [ -d "${SHARED_SPECS}/usr/share/snapdragon/stack" ]; then
    mkdir -p "${SYSROOT}/usr/share/snapdragon/stack"
    cp -r "${SHARED_SPECS}/usr/share/snapdragon/stack/." "${SYSROOT}/usr/share/snapdragon/stack/" 2>/dev/null || true
fi
# Self-hosting: bundle the generator source + a regenerate helper so the running
# desktop can build a fresh, customized ISO (snapdragon-regenerate …).
if ${BUNDLE_SOURCE:-false}; then
    info "Bundling generator source -> /usr/src/snapdragon-generator (regenerate from the desktop)"
    mkdir -p "${SYSROOT}/usr/src/snapdragon-generator"
    tar -C "${SCRIPT_DIR}" --exclude=./.git --exclude=./out --exclude='./snap-*' --exclude='./*.bundle' \
        -cf - . 2>/dev/null | tar -C "${SYSROOT}/usr/src/snapdragon-generator" -xf - 2>/dev/null || true
    if [ -f "${SHARED_SPECS}/usr/sbin/snapdragon-regenerate" ]; then
        cp "${SHARED_SPECS}/usr/sbin/snapdragon-regenerate" "${SYSROOT}/usr/sbin/snapdragon-regenerate"
        chmod +x "${SYSROOT}/usr/sbin/snapdragon-regenerate"
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
    CALAMARES_BRIDGE="snapdragon-calamares-install"; AUTOSTART_NAME="snapdragon-installer-autostart"
    INSTALLER_DESKTOP_TITLE="Snapdragon Installer"
fi
if ${WANT_CALAMARES:-false}; then
    mkdir -p "${SYSROOT}/etc/calamares/modules" "${SYSROOT}/usr/libexec"
    cp "${SHARED_SPECS}/etc/calamares/settings.conf" "${SYSROOT}/etc/calamares/settings.conf" 2>/dev/null || true
    cp "${SHARED_SPECS}/etc/calamares/modules/shellprocess-install.conf" "${SYSROOT}/etc/calamares/modules/" 2>/dev/null || true
    if [ -f "${SHARED_SPECS}/usr/libexec/snapdragon-calamares-install" ]; then
        cp "${SHARED_SPECS}/usr/libexec/snapdragon-calamares-install" "${SYSROOT}/usr/libexec/${CALAMARES_BRIDGE}"
        chmod +x "${SYSROOT}/usr/libexec/${CALAMARES_BRIDGE}"
    fi
    if ${UNAFFILIATED}; then
        # Re-point the shellprocess module at the renamed bridge + drop the
        # nonexistent-scaffold 'snapdragon' branding component reference.
        sed -i "s|/usr/libexec/snapdragon-calamares-install|/usr/libexec/${CALAMARES_BRIDGE}|" \
            "${SYSROOT}/etc/calamares/modules/shellprocess-install.conf" 2>/dev/null || true
        sed -i 's/^branding: snapdragon$/branding: default/' "${SYSROOT}/etc/calamares/settings.conf" 2>/dev/null || true
    else
        # BRANDED path: settings.conf names 'branding: snapdragon', but
        # app-admin/calamares only installs the stock 'default' component and no
        # 'snapdragon' one exists anywhere — Calamares refuses to start when its
        # branding component is unresolvable, leaving the live ISO's graphical-
        # installer boot entry dead. Generate a minimal valid component from the
        # build identity so the graphical installer always boots. (The
        # unaffiliated arm above instead rewrites the reference to 'default'.)
        grep -q '^branding: snapdragon$' "${SYSROOT}/etc/calamares/settings.conf" \
            || { err "calamares settings.conf drifted: 'branding: snapdragon' line not found (the generated branding component would go unused)"; exit 1; }
        info "Calamares branding: generating component 'snapdragon' (${BRAND_TITLE} ${REL_VERSION})"
        _caldir="${SYSROOT}/usr/share/calamares/branding/snapdragon"
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
componentName:  snapdragon

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
    if [ -f "${SHARED_SPECS}/usr/bin/snapdragon-installer-autostart" ]; then
        cp "${SHARED_SPECS}/usr/bin/snapdragon-installer-autostart" "${SYSROOT}/usr/bin/${AUTOSTART_NAME}"
        chmod +x "${SYSROOT}/usr/bin/${AUTOSTART_NAME}"
        if ${UNAFFILIATED}; then
            grep -q 'snapdragon\.install=' "${SYSROOT}/usr/bin/${AUTOSTART_NAME}" \
                || { err "snapdragon-installer-autostart drifted: snapdragon.install= key not found (unaffiliated rename would break silently)"; exit 1; }
            sed -i "s/snapdragon\.install=/${INSTALL_CMDLINE_KEY}=/g" "${SYSROOT}/usr/bin/${AUTOSTART_NAME}"
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
# staging dir (later sources win), copy it into the image, and let snapdragon-
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
    #    root by snapdragon-branding at build AND first boot, so emit every value with
    #    `printf %q` (shell-safe quoting): a dot-sourced file can never execute injected
    #    code even if a value slipped past the up-front validators (defense-in-depth).
    {
        echo "# appended by build-x86-host-stage4.sh"
        printf 'BRAND_NAME=%q\n' "${BRAND}"
        printf 'BRAND_TITLE=%q\n' "${BRAND_TITLE}"
        [ -n "${BRAND_ACCENT}" ] && printf 'ACCENT_COLOR=%q\n' "${BRAND_ACCENT}"
    } >> "${_bd}/brand.conf"
    # stage assets + canonical brand.conf into the image
    mkdir -p "${SYSROOT}/etc/snapdragon/branding"
    cp -r "${_bd}/." "${SYSROOT}/etc/snapdragon/branding/" 2>/dev/null || true
    cp "${_bd}/brand.conf" "${SYSROOT}/etc/snapdragon/brand.conf" 2>/dev/null || true
    # copy the applier, then bake static pieces into the sysroot FROM THE HOST
    cp "${SHARED_SPECS}/usr/sbin/snapdragon-branding" "${SYSROOT}/usr/sbin/snapdragon-branding"; chmod +x "${SYSROOT}/usr/sbin/snapdragon-branding"
    SNAPDRAGON_BRANDING_ROOT="${SYSROOT}" SNAPDRAGON_BRANDING_BUILD=1 \
        bash "${SHARED_SPECS}/usr/sbin/snapdragon-branding" apply "${SYSROOT}/etc/snapdragon/branding" \
        || warn "branding bake reported a problem (continuing)"
    if ${BRAND_LOCKED}; then : > "${SYSROOT}/etc/snapdragon/branding.lock"; info "Branding LOCKED (users cannot re-theme this image)"; fi
    # first-boot hook: re-apply on the real system so the INSTALLED grub.cfg picks up
    # the background (the build-time host run has no grub.cfg / block devices).
    cat > "${SYSROOT}/etc/local.d/04-branding.start" <<'HOOK'
#!/bin/bash
# First-boot: finish branding on the real system (regenerate grub.cfg with the brand
# background). Idempotent; self-removes after a clean run.
[ -x /usr/sbin/snapdragon-branding ] && /usr/sbin/snapdragon-branding apply /etc/snapdragon/branding && rm -f "$0"
HOOK
    chmod +x "${SYSROOT}/etc/local.d/04-branding.start"
    # hand the resolved GRUB background + theme to the live-ISO builder (boot-screen brand)
    [ -f "${SYSROOT}/boot/grub/snapdragon-background.png" ] && BRAND_GRUB_BG_STAGED="${SYSROOT}/boot/grub/snapdragon-background.png"
    [ -f "${SYSROOT}/boot/grub/themes/snapdragon/theme.txt" ] && BRAND_GRUB_THEME_STAGED="${SYSROOT}/boot/grub/themes/snapdragon"
    rm -rf "${_bd}"
    info "Branding baked: $(ls "${SYSROOT}/etc/snapdragon/branding" 2>/dev/null | tr '\n' ' ')"
fi

# ── Egress VPN (NetworkManager) staging ──────────────────────────────────────
# Drop the admin's egress conf into the image + the snapdragon-egress-vpn tool; first
# boot imports it into NetworkManager (NM must be running, so this is a boot hook, not
# a build-time bake). Split-tunnel keeps the tailnet + LAN direct. --egress-vpn-locked
# makes a managed node: autoconnect + user cannot remove (an NM dispatcher re-asserts).
if ! ${ROLE_CLIENT} && [ -n "${EGRESS_VPN_FILE}" ]; then
    warn "--egress-vpn given for a non-desktop role (${ROLE}); egress VPN is a desktop/tailnet-node feature — ignoring."
fi
if ${ROLE_CLIENT} && [ -n "${EGRESS_VPN_FILE}" ]; then
    [ -f "${EGRESS_VPN_FILE}" ] || { err "--egress-vpn file not found: ${EGRESS_VPN_FILE}"; exit 1; }
    banner "Staging egress VPN (locked=${EGRESS_VPN_LOCKED})"
    mkdir -p "${SYSROOT}/etc/snapdragon/egress"
    cp "${EGRESS_VPN_FILE}" "${SYSROOT}/etc/snapdragon/egress/$(basename "${EGRESS_VPN_FILE}")"
    chmod 600 "${SYSROOT}/etc/snapdragon/egress/"* 2>/dev/null || true
    cp "${SHARED_SPECS}/usr/sbin/snapdragon-egress-vpn" "${SYSROOT}/usr/sbin/snapdragon-egress-vpn"; chmod +x "${SYSROOT}/usr/sbin/snapdragon-egress-vpn"
    if ${EGRESS_VPN_LOCKED}; then : > "${SYSROOT}/etc/snapdragon/egress/locked"; info "Egress VPN LOCKED (managed node: user cannot remove)"; fi
    # first-boot import (NM is up by the time local.d runs); bring it up if locked.
    cat > "${SYSROOT}/etc/local.d/05-egress-vpn.start" <<'HOOK'
#!/bin/bash
# First-boot: import the egress VPN into NetworkManager. Self-removes ONLY on a
# successful import, so an NM-not-ready race on first boot retries next boot instead
# of permanently losing the connection.
if [ -x /usr/sbin/snapdragon-egress-vpn ]; then
    if /usr/sbin/snapdragon-egress-vpn import; then
        [ -e /etc/snapdragon/egress/locked ] && /usr/sbin/snapdragon-egress-vpn up || true
        rm -f "$0"
    fi
fi
HOOK
    chmod +x "${SYSROOT}/etc/local.d/05-egress-vpn.start"
    # When locked, re-assert on every NM connectivity change so a deleted connection
    # comes back (defense-in-depth alongside the tool's refuse-when-locked).
    if ${EGRESS_VPN_LOCKED}; then
        mkdir -p "${SYSROOT}/etc/NetworkManager/dispatcher.d"
        cat > "${SYSROOT}/etc/NetworkManager/dispatcher.d/90-snapdragon-egress" <<'DISP'
#!/bin/bash
# Re-assert the locked egress VPN whenever NetworkManager signals a change.
[ -x /usr/sbin/snapdragon-egress-vpn ] && /usr/sbin/snapdragon-egress-vpn ensure || true
DISP
        chmod +x "${SYSROOT}/etc/NetworkManager/dispatcher.d/90-snapdragon-egress"
        # polkit: on a managed node, only wheel (admins) may modify/delete SYSTEM NM
        # connections — so a non-admin user cannot remove the locked egress via nmcli or
        # the network applet (the tool's refuse-when-locked + the dispatcher re-assert
        # are the other two layers). enable-disable/network-control stay open so the
        # user can still use Wi-Fi etc.
        mkdir -p "${SYSROOT}/etc/polkit-1/rules.d"
        cat > "${SYSROOT}/etc/polkit-1/rules.d/49-snapdragon-egress-lock.rules" <<'POLKIT'
// Snapdragon managed egress node: restrict modification/deletion of system-wide
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
# UNAFFILIATED: no /etc/snapdragon marker tree at all — every consumer of these
# markers (keys-provision, snapdragon-update, provision-time tooling) is platform
# machinery this image does not carry. The one FUNCTIONAL conf (home.conf) is
# written to the neutral /etc/gentoo/ above instead.
if ! ${UNAFFILIATED}; then
mkdir -p "${SYSROOT}/etc/snapdragon" "${SYSROOT}/var/lib/snapdragon"
echo "${ROLE}"           > "${SYSROOT}/etc/snapdragon/role"
echo "${CLUSTER_DOMAIN}" > "${SYSROOT}/etc/snapdragon/cluster-domain"
# Runtime ENV marker (test|prod). Read by bootstrap/provision; also documents
# the image's posture. test => LAN wildcard DNS authoritative; prod => public.
echo "${ENV}"            > "${SYSROOT}/etc/snapdragon/env"
# Bake the brand's mesh control-server URL so keys-provision can read it at
# first boot (env does not survive to first boot). Empty = local-first: the
# control node defaults server_url to its own LAN IP (resolve_endpoint).
if [ -n "${HEADSCALE_URL:-}" ]; then
    echo "${HEADSCALE_URL}" > "${SYSROOT}/etc/snapdragon/headscale-url"
    info "Baked HEADSCALE_URL=${HEADSCALE_URL} -> /etc/snapdragon/headscale-url"
fi
fi   # ! UNAFFILIATED (marker tree)
# Orchestration superdomain (WS-SUPER-B): bake the mesh plane's MagicDNS suffix so the
# image RECORDS the plane it belongs to. Self-contained brand-etc fold like secureboot
# (SB_ETC_DIR): affiliated -> /etc/snapdragon, unaffiliated -> /etc/gentoo. Only ever set
# on a MESH build (the Studio's gate), and an unaffiliated desktop is standalone and never
# mesh, so the /etc/gentoo branch is belt-and-braces. This is the AUTHORITATIVE on-image
# bake; the KEYS/provision channel remains the secret side.
if [ -n "${SUPERDOMAIN}" ]; then
    if ${UNAFFILIATED}; then _sd_etc="/etc/gentoo"; else _sd_etc="/etc/snapdragon"; fi
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
    echo "${PERSON_ROLE}" > "${SYSROOT}/etc/snapdragon/identity-role"
    { for d in ${DOMAINS//,/ }; do echo "${d}"; done; } > "${SYSROOT}/etc/snapdragon/domains"
    echo "${DESKTOP}"     > "${SYSROOT}/etc/snapdragon/desktop-weight"
    if ${STANDALONE}; then
        # STANDALONE desktop: a self-contained personal workstation. Bake the marker
        # so keys-provision + firstboot SKIP all Casdoor/OIDC/mesh provisioning and a
        # normal LOCAL USER logs in with the build-set password (no domain/SSO tie).
        echo "true" > "${SYSROOT}/etc/snapdragon/standalone"
        info "Standalone desktop: local user '${DEFAULT_USER}', no SSO/mesh/domain tie."
    fi
    # Login-side unlock factor markers (enrolled at first login; the device must be
    # present). Boot-side factors are handled by the installer (LUKS keyslots).
    [ "${UNLOCK_KEYFILE}" = "login" ] && { echo "keyfile" > "${SYSROOT}/etc/snapdragon/unlock-login"; info "Login factor: keyfile (enroll at first login)."; }
    [ "${UNLOCK_YUBIKEY}" = "login" ] && { echo "yubikey" > "${SYSROOT}/etc/snapdragon/unlock-login"; info "Login factor: YubiKey/pam_u2f (run pamu2fcfg at first login)."; }
    # superadmin field device (FD-04/FD-06): require a SEPARATE device password set at
    # first boot from a salted+hashed value on the KEYS USB (NEVER baked into the image
    # — mirrors the Casdoor superadmin-seed custody). The marker tells keys-provision's
    # provision_device_password() to enforce it. Standalone has no superadmin/Casdoor
    # concept, so it never sets this. See docs/CLIENT-IMAGES.md.
    if [ "${PERSON_ROLE}" = "superadmin" ] && ! ${STANDALONE}; then
        : > "${SYSROOT}/etc/snapdragon/device-password-required"
        info "Client device: superadmin variant — device password REQUIRED at first boot (hash from KEYS, not baked)"
    fi
    info "Client device: person-role=${PERSON_ROLE} domains='${DOMAINS:-<provision-time>}' desktop=${DESKTOP} (no k8s cluster payload)"
    rebrand_sysroot       # still rebrand markers/desktop configs snapdragon.systems -> ${CLUSTER_DOMAIN}
else
    cp -r "${SHARED_SPECS}/cluster" "${SYSROOT}/var/lib/snapdragon/cluster"
    # Only parameterize the games host URLs when games is actually selected; when
    # games is opt-out (default) gate_optional_services prunes it below anyway.
    case " ${OPTIONAL_SERVICES} " in
        *" games "*) parameterize_games_domain ;;  # rewrite .games -> ${GAMES_DOMAIN} (BEFORE rebrand; fixes games OIDC iss on the subdomain default)
    esac
    gate_env_apps             # prune ENV-specific ArgoCD apps from the baked copy
    bake_host_firewall        # Layer 3: host nftables backstop for RELEASE_STATE (independent of gate_env_apps' K8s-manifest layer)
    gate_optional_services    # prune OPTIONAL services (akkoma/tuwunel/phpbb/games) not in OPTIONAL_SERVICES
    rebrand_sysroot           # rewrites snapdragon.systems -> ${CLUSTER_DOMAIN} (incl. lan-dns/cloudflared/games)
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
        SVCS=(sshd NetworkManager cronie haveged growroot firewall auditd local dbus elogind display-manager)
    else
        SVCS=(sshd NetworkManager cronie haveged growroot keys-provision firewall auditd local dbus elogind display-manager)
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
        if ${UNAFFILIATED}; then _md_name="media-detect"; _md_conf_dir="/etc/gentoo"; else _md_name="snapdragon-media-detect"; _md_conf_dir="/etc/snapdragon"; fi
        mkdir -p "${SYSROOT}${_md_conf_dir}" "${SYSROOT}/usr/sbin"
        render_template "${SHARED_SPECS}/etc/snapdragon/media.conf.tmpl" "${SYSROOT}${_md_conf_dir}/media.conf"
        cp "${SHARED_SPECS}/usr/sbin/snapdragon-media-detect" "${SYSROOT}/usr/sbin/${_md_name}"; chmod +x "${SYSROOT}/usr/sbin/${_md_name}"
        cp "${SHARED_SPECS}/etc/init.d/snapdragon-media-detect" "${SYSROOT}/etc/init.d/${_md_name}"; chmod +x "${SYSROOT}/etc/init.d/${_md_name}"
        if ${UNAFFILIATED}; then
            grep -q '^CONF=/etc/snapdragon/media.conf' "${SYSROOT}/usr/sbin/${_md_name}" \
                || { err "snapdragon-media-detect drifted: CONF= line not found (unaffiliated rename would break silently)"; exit 1; }
            sed -i -e "s|/etc/snapdragon/media.conf|${_md_conf_dir}/media.conf|g" \
                   -e "s|/usr/sbin/snapdragon-media-detect|/usr/sbin/${_md_name}|g" \
                "${SYSROOT}/usr/sbin/${_md_name}" "${SYSROOT}/etc/init.d/${_md_name}"
        fi
        SVCS+=("${_md_name}")
        unset _md_name _md_conf_dir
        info "Media-data: /media auto-detect + Steam->${STEAM_DIR} + Vaults (gocryptfs) wired (steam=${STEAM_DELIVERY})"
    fi
else
    SVCS=(sshd NetworkManager cronie haveged growroot keys-provision firewall snapdragon-firewall-reconcile snapdragon-go-live-reconcile containerd kubelet auditd local)
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
# /etc/snapdragon/registry/cron-domain-reconcile) is installed alongside.
if ! ${ROLE_CLIENT} && _opt_selected domain-registry-bridge; then
    SVCS+=(snapdragon-domain-reconcile)
    if [ -f "${SYSROOT}/etc/snapdragon/registry/cron-domain-reconcile" ]; then
        mkdir -p "${SYSROOT}/etc/cron.d"
        cp -f "${SYSROOT}/etc/snapdragon/registry/cron-domain-reconcile" \
              "${SYSROOT}/etc/cron.d/snapdragon-domain-reconcile"
        info "OPTIONAL_SERVICES: domain-registry-bridge selected — linked snapdragon-domain-reconcile + 60s cron"
    fi
fi

# Tor v3 onion (hidden) service (DEFAULT-OFF optional service): link ONLY the snapdragon
# reconcile agent into the default runlevel when 'tor' is selected AND this is a k8s node
# (a CLIENT desktop is not a cluster member) — mirroring egress-vpn, which links only its
# reconcile agent, not the daemon. The DISTRO `tor` service is NOT linked here: the
# reconcile agent OWNS tor's lifecycle (writes the managed torrc, mints the v3 onion
# keypair OFF-GIT under /var/lib/tor/snapdragon-onion, then `rc-service tor restart`),
# avoiding any double-start. The 24h refresh cron (staged at
# /etc/snapdragon/registry/cron-tor-reconcile) is installed alongside. Unselected =>
# reconcile not linked + net-vpn/tor absent => ZERO execution.
if ! ${ROLE_CLIENT} && _opt_selected tor; then
    SVCS+=(snapdragon-tor-reconcile)
    if [ -f "${SYSROOT}/etc/snapdragon/registry/cron-tor-reconcile" ]; then
        mkdir -p "${SYSROOT}/etc/cron.d"
        cp -f "${SYSROOT}/etc/snapdragon/registry/cron-tor-reconcile" \
              "${SYSROOT}/etc/cron.d/snapdragon-tor-reconcile"
        info "OPTIONAL_SERVICES: tor selected — linked snapdragon-tor-reconcile + 24h cron (reconcile agent owns the tor daemon; v3 onion keypair off-git, minted first-boot)"
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

# ── 5. Chroot setup + native emerge ────────────────────────────────
banner "Native emerge inside chroot"

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
if [ -n "${EGRESS_VPN_FILE}" ]; then
    case "${EGRESS_VPN_FILE}" in
        *.ovpn) PKGS="${PKGS} net-vpn/networkmanager-openvpn net-vpn/openvpn" ;;
        *)      PKGS="${PKGS} net-vpn/wireguard-tools" ;;
    esac
fi
# Tor NODE service (DEFAULT-OFF optional service): the v3 onion daemon (net-vpn/tor,
# which ships /etc/init.d/tor + /etc/tor/torrc + the tor:tor user). Only added when
# 'tor' is selected (parity with the egress-vpn package gate); otherwise the image does
# not carry it. net-vpn/tor inherits USE=selinux from a SELinux node profile, giving the
# upstream tor_t confinement the reconcile agent's snapdragon_tor.te references.
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
STEAM_OVERLAY_SETUP=""
if ${STEAM_NATIVE}; then
    STEAM_OVERLAY_SETUP='
echo "[build-x86] Native Steam: enabling + syncing the steam-overlay"
emerge --noreplace --quiet-build app-eselect/eselect-repository 2>/dev/null || emerge --quiet-build app-eselect/eselect-repository || true
eselect repository enable steam-overlay 2>/dev/null || true
emaint sync -r steam-overlay 2>/dev/null || emerge --sync steam-overlay 2>/dev/null || echo "[build-x86] WARN: steam-overlay sync failed; native Steam may not resolve (rebuild with --steam flatpak)"'
fi
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
# Apply our profile/USE across @world without churning the toolchain.
emerge --update --deep --newuse --keep-going ${EMERGE_EXCLUDE} @world \
    || echo "[build-x86] WARN: @world had package failures (--keep-going); continuing"
# Ensure the stage4 package set is present (deps included).
# --autounmask-continue auto-applies any required USE-flag change and continues
# the merge (so a dep needing e.g. a USE flag doesn't ABORT resolution the way a
# bare emerge does), but --autounmask-keep-keywords / -keep-masks keep keyword &
# mask decisions EXPLICIT — those are pre-seeded in package.accept_keywords for a
# reproducible hardened build rather than silently pulling unstable/masked pkgs.
emerge --update --deep --newuse --keep-going \
    --autounmask-continue=y --autounmask-keep-keywords=y --autounmask-keep-masks=y \
    ${EMERGE_EXCLUDE} ${PKGS} \
    || { echo "[build-x86] WARN: some stage4 packages failed; review the emerge output"
         # DIAGNOSTIC: --autounmask-continue is NOT applying needed USE changes in
         # this chroot, so resolution dies one conflict at a time. A PRETEND
         # --autounmask pass computes the COMPLETE set of USE changes the payload
         # needs in one go — dump it so they can all be pre-seeded into the
         # package.use specs at once instead of whack-a-mole.
         echo "[build-x86] ===== AUTOUNMASK-PRETEND: full USE/keyword changes the payload needs ====="
         emerge --pretend --autounmask=y --autounmask-write=n --autounmask-backtrack=y \
             --keep-going ${EMERGE_EXCLUDE} ${PKGS} 2>&1 \
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
CHROOT

# ── 6. Mesh VPN (amd64 static binaries) ────────────────────────────
if ${SKIP_MESH}; then
    banner "Mesh VPN SKIPPED"
else
    banner "Installing mesh VPN (headscale + tailscale, amd64)"
    # Pinned versions (HEADSCALE_VERSION / TAILSCALE_VERSION) + publisher checksum
    # verification: headscale releases ship checksums.txt; tailscale ships a
    # <tgz>.sha256 sidecar. Fetch the manifest, verify sha256, ABORT on any
    # mismatch — a tampered binary can no longer reach the mesh runlevel.
    # (Mirrors the rpi5/frite/jetson builders' Phase 2.5 verification.)
    HS_REL="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}"
    HS_BIN="${SYSROOT}/usr/bin/headscale"
    if curl -fL --retry 5 --retry-delay 5 --retry-connrefused --retry-all-errors -o "${HS_BIN}" \
        "${HS_REL}/headscale_${HEADSCALE_VERSION}_linux_amd64"; then
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
        if curl -fL --retry 5 --retry-delay 5 --retry-connrefused --retry-all-errors -o "${TGZ}" "${TS_URL}"; then
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
if ${SKIP_KERNEL}; then
    banner "Kernel SKIPPED"
else
    banner "Building Gentoo hardened kernel (gentoo-sources + KSPP/SELinux + k8s fragment)"
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
    chroot "${SYSROOT}" /bin/bash -eo pipefail <<CHROOT
KBUILTIN=${KERNEL_BUILTIN}
# (Re)ensure the hardened kernel sources are installed and /usr/src/linux is set
# — independent of whether the main stage4 emerge completed.
if [ ! -e /usr/src/linux/Makefile ]; then
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
# The live squashfs root carries the SELinux security.selinux labels as xattrs; without
# this the kernel drops them ("squashfs: Xattrs in filesystem, these will be ignored"),
# the live root is UNLABELED, and the enforcing boot DEADLOCKS at OpenRC init-early
# (proven via QEMU: enforcing hangs, enforcing=0 reaches agetty). SQUASHFS_XATTR depends
# on SQUASHFS, so a pruned dep would silently re-strip the labels — fail closed here.
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
# (snapdragon-unsigned.efi) and UNAFFILIATED (gentoo-unsigned.efi) names.
# --kernel-image /boot/vmlinuz is REQUIRED: 'make install' above ran with no
# installkernel(8) (see the LILO note), so arch/x86/boot/install.sh wrote an
# UNVERSIONED /boot/vmlinuz — dracut's determine_kernel_image() probes only
# versioned paths (/lib/modules/<kver>/vmlinuz, /boot/vmlinuz-<kver>, ...) and
# dies "Can't find a kernel image" without the flag; the WARN below would then
# swallow that and the SB chain would silently degrade to GRUB+vmlinuz
# (live-proven on the real desktop sysroot: exact invocation failed without
# the flag, produced a valid PE32+ UKI with it).
CMDLINE="\$(. /etc/default/grub 2>/dev/null; printf '%s' "\${GRUB_CMDLINE_LINUX:-lsm=lockdown,yama,selinux,bpf lockdown=integrity selinux=1 audit=1}")"
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
    rm -f "${SYSROOT}/tmp/k.config"
    info "Gentoo hardened kernel + disk-boot initramfs installed to ${SYSROOT}/boot"
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
        info "Generating Snapdragon org Secure Boot signing key (RSA-4096, 10 yr)"
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
fi

# ── 9. Stage4 tarball ──────────────────────────────────────────────
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
tar -C "${SYSROOT}" --xattrs-include='*.*' --numeric-owner \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' --exclude='./run/*' \
    --exclude='./var/cache' --exclude='./tmp/*' --exclude='./usr/src' --exclude='./home/magus' -cpf - . 2>/dev/null \
    | xz -T0 -6 > "${STAGE4}" \
  || tar -C "${SYSROOT}" --numeric-owner \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' --exclude='./run/*' \
    --exclude='./var/cache' --exclude='./tmp/*' --exclude='./usr/src' --exclude='./home/magus' -cpf - . | xz -T0 -6 > "${STAGE4}"
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
        echo "insmod search_fs_uuid"
        echo "insmod chainloader"
        # UKI entry: direct chainload from ESP — preferred when Secure Boot is active.
        if [ -f "${root_mnt}/boot/efi/EFI/Linux/${UKI_NAME}" ]; then
            echo "menuentry \"${BRAND_TITLE} (${ROLE}) — Secure Boot UKI\" {"
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
    banner "SKIPPED .img (--no-img)"
fi

# ── 11. ISOs (live + installer, both opt-in) ───────────────────────
ISO_PATH="(not built)"
if ! ${SKIP_ISO}; then
    KVER="$(ls "${SYSROOT}/lib/modules" 2>/dev/null | sort -V | tail -1)"
    VMLINUZ="$(ls -1 "${SYSROOT}/boot/vmlinuz-"* "${SYSROOT}/boot/vmlinuz" 2>/dev/null | sort -V | tail -1 || true)"

    if ${LIVE_ISO} && [ -n "${VMLINUZ}" ] && [ -n "${KVER}" ]; then
        ISO_PATH="${WORK_DIR}/${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.live.iso"
        banner "Building bootable LIVE ISO (grub-mkrescue + squashfs)"
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
        [ -n "${BRAND_GRUB_BG_STAGED:-}" ] && cp "${BRAND_GRUB_BG_STAGED}" "${ISO_DIR}/boot/grub/snapdragon-background.png" 2>/dev/null || true
        if [ -n "${BRAND_GRUB_THEME_STAGED:-}" ] && [ -d "${BRAND_GRUB_THEME_STAGED}" ]; then
            mkdir -p "${ISO_DIR}/boot/grub/themes/snapdragon"
            cp -r "${BRAND_GRUB_THEME_STAGED}/." "${ISO_DIR}/boot/grub/themes/snapdragon/" 2>/dev/null || true
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
                -comp "${sq_comp}" -e proc sys dev run var/cache/distfiles home/magus >/dev/null \
                || { err "mksquashfs failed — cannot build a bootable live ISO"; exit 1; }
        else
            # squashfs-tools-ng fallback: same excludes, xz (kernel has SQUASHFS_XZ).
            info "Squashing rootfs with tar2sqfs -c xz (this can take a while)..."
            tar -C "${SYSROOT}" --numeric-owner \
                --exclude='./proc' --exclude='./sys' --exclude='./dev' \
                --exclude='./run' --exclude='./var/cache/distfiles' --exclude='./home/magus' \
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
        # env and autostart the installer via the snapdragon.install= cmdline. The
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
            if [ -f "${ISO_DIR}/boot/grub/snapdragon-background.png" ] \
                    || [ -f "${ISO_DIR}/boot/grub/themes/snapdragon/theme.txt" ]; then
                echo "insmod all_video"
                echo "insmod png"
                echo "insmod gfxterm"
                echo "set gfxmode=1920x1080,1280x720,auto"
                echo "terminal_output gfxterm"
                if [ -f "${ISO_DIR}/boot/grub/themes/snapdragon/theme.txt" ]; then
                    echo "insmod gfxmenu"
                    [ -f "${ISO_DIR}/boot/grub/themes/snapdragon/font.pf2" ] \
                        && echo "loadfont /boot/grub/themes/snapdragon/font.pf2"
                    echo "set theme=/boot/grub/themes/snapdragon/theme.txt"
                fi
                [ -f "${ISO_DIR}/boot/grub/snapdragon-background.png" ] \
                    && echo "background_image /boot/grub/snapdragon-background.png"
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
        _shim_src="$(find /usr/share/shim /usr/lib/shim 2>/dev/null \
            \( -name 'BOOTX64.EFI' -o -name 'shimx64.efi' \) 2>/dev/null | head -1 || true)"
        if [ -f "${ISO_PATH}" ] && [ -n "${_shim_src}" ] && [ -f "${_shim_src}" ] \
                && command -v xorriso >/dev/null && command -v grub-mkstandalone >/dev/null; then
            info "Post-processing live ISO to add shim (Secure Boot: shim→signed GRUB→kernel)"
            _iso_tmp="${ISO_PATH}.shim-work"
            mkdir -p "${_iso_tmp}/EFI/BOOT"
            # Extract GRUB EFI from the ISO into grubx64.efi.
            xorriso -indev "${ISO_PATH}" -osirrox on \
                -extract EFI/BOOT/BOOTX64.EFI "${_iso_tmp}/EFI/BOOT/grubx64.efi" 2>/dev/null || true
            # Sign GRUB with org key if available.
            if [ -f "${_iso_tmp}/EFI/BOOT/grubx64.efi" ] \
                    && command -v sbsign >/dev/null && [ -f "${SBKEY:-}" ]; then
                sbsign --key "${SBKEY}" --cert "${SBCRT}" \
                    --output "${_iso_tmp}/EFI/BOOT/grubx64.efi" \
                    "${_iso_tmp}/EFI/BOOT/grubx64.efi" 2>/dev/null \
                    && info "Live GRUB EFI signed with org key"
            fi
            # Add shim + MOK manager.
            cp "${_shim_src}" "${_iso_tmp}/EFI/BOOT/BOOTX64.EFI"
            _mmgr="$(find /usr/share/shim /usr/lib/shim 2>/dev/null \
                \( -name 'mmx64.efi' -o -name 'MokManager.efi' \) | head -1 || true)"
            [ -n "${_mmgr}" ] && cp "${_mmgr}" "${_iso_tmp}/EFI/BOOT/mmx64.efi" 2>/dev/null || true
            # Add org cert for enrollment inside live env. SB_ETC_DIR/SB_EFI_VENDOR
            # come from the boot-chain identity fold (same resolution as the
            # stager), so UNAFFILIATED media carries the cert under the neutral
            # EFI/gentoo/ dir.
            if [ -d "${SYSROOT}${SB_ETC_DIR}" ]; then
                mkdir -p "${_iso_tmp}/EFI/${SB_EFI_VENDOR}"
                cp "${SYSROOT}${SB_ETC_DIR}"/*.{crt,cer,auth} \
                   "${_iso_tmp}/EFI/${SB_EFI_VENDOR}/" 2>/dev/null || true
            fi
            # Patch the ISO: replace EFI directory with shim-based structure.
            _iso_new="${ISO_PATH%.iso}-sb.iso"
            xorriso -indev "${ISO_PATH}" -outdev "${_iso_new}" \
                -map "${_iso_tmp}/EFI/BOOT/BOOTX64.EFI" "/EFI/BOOT/BOOTX64.EFI" \
                -map "${_iso_tmp}/EFI/BOOT/grubx64.efi"  "/EFI/BOOT/grubx64.efi" \
                $([ -f "${_iso_tmp}/EFI/BOOT/mmx64.efi" ] && \
                  echo "-map ${_iso_tmp}/EFI/BOOT/mmx64.efi /EFI/BOOT/mmx64.efi") \
                $([ -d "${_iso_tmp}/EFI/${SB_EFI_VENDOR}" ] && \
                  echo "-map ${_iso_tmp}/EFI/${SB_EFI_VENDOR} /EFI/${SB_EFI_VENDOR}") \
                -- 2>/dev/null \
                && { mv "${_iso_new}" "${ISO_PATH}"; info "Shim added to live ISO (Secure Boot ready)"; } \
                || { warn "xorriso shim post-processing failed; live ISO uses bare GRUB (no shim)"; rm -f "${_iso_new}"; }
            rm -rf "${_iso_tmp}"
        elif [ -f "${ISO_PATH}" ]; then
            info "Shim not found on build host (install sys-boot/shim); live ISO uses bare GRUB (no Secure Boot chain)"
        fi
        fi
    elif ${LIVE_ISO}; then
        warn "Live ISO requested but no vmlinuz/modules present — skipping (don't pass --skip-kernel)"
    fi

    if ${INSTALLER_ISO}; then
        INSTALLER_ISO_PATH="${WORK_DIR}/${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.installer.iso"
        banner "Building installer ISO (stage4 + install-x86.sh; boot a live USB to install)"
        INST_DIR="${BUILD_ROOT}/isoroot-installer"
        rm -rf "${INST_DIR}"; mkdir -p "${INST_DIR}/stage4"
        cp "${STAGE4}" "${INST_DIR}/stage4/"
        cp "${SPECS_DIR}/installer/install-x86.sh" "${INST_DIR}/install-x86.sh"; chmod +x "${INST_DIR}/install-x86.sh"
        # UNAFFILIATED: neutralize the STAGED installer copy — UI titles, the
        # cmdline key it greps, the home.conf path it sources, and the partition
        # labels it formats. Functional patterns are asserted first so upstream
        # drift fails the build loudly instead of shipping a half-neutral ISO.
        if ${UNAFFILIATED}; then
            for _pat in 'snapdragon.install=ncurses' '/etc/snapdragon/home.conf' 'SNAP_ESP' 'SNAP_ROOT' \
                        '# Snapdragon x86_64 installer'; do
                grep -qF "${_pat}" "${INST_DIR}/install-x86.sh" \
                    || { err "install-x86.sh drifted: '${_pat}' not found (unaffiliated neutralization would break silently)"; exit 1; }
            done; unset _pat
            sed -i \
                -e "s/snapdragon\.install=/${INSTALL_CMDLINE_KEY}=/g" \
                -e "s|/etc/snapdragon/home.conf|${HOME_CONF_DIR}/home.conf|g" \
                -e "s/\bSNAP_ESP\b/${ESP_LABEL}/g" -e "s/\bSNAP_ROOT\b/${ROOT_LABEL}/g" \
                -e 's/Snapdragon Installer/Gentoo Installer/g' \
                -e 's/Install Snapdragon onto/Install Gentoo onto/g' \
                -e 's/# Snapdragon encrypted-root layout/# Encrypted-root layout/' \
                -e 's/# Snapdragon x86_64 installer.*/# Gentoo x86_64 installer (hardened desktop, optional GPU)./' \
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
echo "  Profile:    $(cat "${SYSROOT}/etc/portage/profile/parent")"
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
    echo "  Labels:     ${ROLE_LABELS}  (set on the KEYS stick: .snapdragon.node_labels)"
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
        be)      echo "    ./scripts/gen-provision-keys.sh -r backend -o keys-${ROLE_TAG}    # worker; label snapdragon.systems/backend=true" ;;
        fe)      echo "    ./scripts/gen-provision-keys.sh -r frontend -o keys-${ROLE_TAG}   # worker; label snapdragon.systems/frontend=true" ;;
        be+gpu)  echo "    ./scripts/gen-provision-keys.sh -r backend -o keys-${ROLE_TAG}    # worker; edit:";
                 echo "    snapdragon.role=games, node_labels { snapdragon.systems/compute: gpu }" ;;
        omnibus) echo "    ./scripts/gen-provision-keys.sh -r pki -o keys-${ROLE_TAG}        # single-node CP; all labels (pki/backend/frontend/compute=gpu)" ;;
    esac
fi

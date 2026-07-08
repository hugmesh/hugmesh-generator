#!/usr/bin/env bash
# build_menu_cmd_test.sh — unit checks for scripts/build-menu.sh build_make_cmd().
#
# Sources the menu script (its execute-guard keeps it non-interactive when
# sourced), sets representative OPT_* option permutations and asserts the
# composed `make` argument list (RUN_MAKE). Needs NO TTY, NO whiptail and runs
# in seconds — safe for CI.
#
#   bash tests/menu/build_menu_cmd_test.sh
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/../.." && pwd)"

# Isolate the menu's persistent state so the tester's REAL saved menu.conf never
# leaks into (or gets clobbered by) the assertions.
SNAP_MENU_STATE="$(mktemp -d)"; export SNAP_MENU_STATE
trap 'rm -rf "${SNAP_MENU_STATE}"' EXIT
export NO_TUI=1

# shellcheck disable=SC1091
source "${REPO_DIR}/scripts/build-menu.sh"

PASS=0; FAIL=0
_ok()   { PASS=$((PASS+1)); }
_bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n  make args: %s\n' "$1" "${RUN_MAKE[*]}" >&2; }

# assert_has NAME SUBSTR — some RUN_MAKE element must CONTAIN SUBSTR
assert_has() {
    local e
    for e in "${RUN_MAKE[@]}"; do case "${e}" in *"$2"*) _ok; return 0 ;; esac; done
    _bad "$1: missing '$2'"
}
# assert_not NAME SUBSTR — NO RUN_MAKE element may contain SUBSTR
assert_not() {
    local e
    for e in "${RUN_MAKE[@]}"; do case "${e}" in *"$2"*) _bad "$1: unexpected '$2'"; return 1 ;; esac; done
    _ok
}
# assert_one_flags NAME — at most ONE STANDALONE_FLAGS= element per invocation
assert_one_flags() {
    local n=0 e
    for e in "${RUN_MAKE[@]}"; do case "${e}" in STANDALONE_FLAGS=*) n=$((n+1)) ;; esac; done
    [ "${n}" -le 1 ] && _ok || _bad "$1: ${n} STANDALONE_FLAGS elements (want <=1)"
}
# assert_eq NAME GOT WANT
assert_eq() { [ "$2" = "$3" ] && _ok || { FAIL=$((FAIL+1)); printf 'FAIL %s: got %q want %q\n' "$1" "$2" "$3" >&2; }; }

# Reset every option build_make_cmd reads to a known baseline (the script's own
# defaults) so each case only states its deltas.
reset_opts() {
    OPT_WORK_DIR=/tmp/menu-test-out OPT_JOBS=4 OPT_ENV=test OPT_PATH=docker
    OPT_BRAND="" OPT_DOMAIN="" OPT_RESUME=no OPT_OMNIBUS=no OPT_PENTEST=no
    OPT_FRITE_FLEET=no OPT_JETSON_FLEET=no
    OPT_IMGFLAGS="" OPT_X86_EDGE_AI=no OPT_EDGE_AI_RUNTIME=ollama
    OPT_EDGE_AI_MODELS="" OPT_EDGE_AI_MODEL_DEFAULT="" OPT_X86_EDGE_AI_ANALYSIS=no
    OPT_TOR_ONION=no OPT_CHARACTER_STUDIO=no OPT_SERVICES="" OPT_INSTALLER_UI=""
    OPT_EXTRA_FLAGS=""
    OPT_BR_WALLPAPER="" OPT_BR_GRUB_BG="" OPT_BR_LOGIN_BG="" OPT_BR_LOGO=""
    OPT_BR_ACCENT="" OPT_BR_SCHEME=""
    OPT_HOME_MODE="" OPT_HOME_DEVICE="" OPT_HOME_BACKUP="" OPT_HOME_ENCRYPTED=no
    OPT_HOME_SEED="" OPT_HOME_ARCHIVE=""
    OPT_FRITE_BOARD=la-frite OPT_FRITE_FLAVOR=both OPT_FRITE_DESKTOP=light
    OPT_SA_GPU=all-free OPT_SA_STEAM=native OPT_SA_MEDIA=yes OPT_SA_USER=snap
    OPT_SA_KEYFILE=none OPT_SA_YUBIKEY=none OPT_SA_THEME=boogiepop OPT_SA_PROXY=yes
    OPT_SA_SNORT=yes OPT_SA_AIDE=no OPT_SA_KBUILTIN=no OPT_SA_EGRESS=""
    OPT_SA_MEDIA_LABEL="" OPT_ROOT_LOGIN=no SA_LOCAL_PASS="" SA_LUKS_PASS=""
    OPT_JETSON_BOARD=orin-nano OPT_JETSON_KFLAVOR=mainline
}

# ── fleet build: RESUME/X86_OMNIBUS/FRITE_FLEET/JETSON_FLEET/PENTEST gate to ────
# BOTH fleet targets (build-all AND build-everything — a prior version of this
# menu entry gated build-everything out entirely, silently dropping Resume/
# pentest/fleet-toggle options the moment a user picked "★ FULL matrix").
reset_opts; OPT_RESUME=yes OPT_OMNIBUS=yes OPT_FRITE_FLEET=yes OPT_JETSON_FLEET=yes OPT_PENTEST=yes
build_make_cmd build-all "fleet" 7
assert_eq  "fleet: target first"        "${RUN_MAKE[0]}" "build-all"
assert_has "fleet: resume"              "RESUME=--resume"
assert_has "fleet: omnibus"             "X86_OMNIBUS=1"
assert_has "fleet: frite fleet"         "FRITE=1"
assert_has "fleet: jetson fleet"        "JETSON=1"
assert_has "fleet: pentest"             "PENTEST=1"
build_make_cmd build-everything "everything" 20
assert_eq  "everything: target first"   "${RUN_MAKE[0]}" "build-everything"
assert_has "everything: resume"         "RESUME=--resume"
assert_has "everything: omnibus"        "X86_OMNIBUS=1"
assert_has "everything: frite fleet"    "FRITE=1"
assert_has "everything: jetson fleet"   "JETSON=1"
assert_has "everything: pentest"        "PENTEST=1"
build_make_cmd x86-be "one role" 1
assert_not "single role: no RESUME"     "RESUME="
assert_not "single role: no X86_OMNIBUS" "X86_OMNIBUS="
assert_not "single role: no FRITE"      "FRITE="
assert_not "single role: no JETSON"     "JETSON="
assert_not "single role: no PENTEST"    "PENTEST="
# with the toggles off, build-everything must not gain a redundant emit either
reset_opts
build_make_cmd build-everything "everything default" 20
assert_not "everything default: no RESUME" "RESUME="
assert_not "everything default: no PENTEST" "PENTEST="

# ── optional-services catalog on a cluster role ─────────────────────────────────
reset_opts; OPT_SERVICES="akkoma,games,tube" OPT_TOR_ONION=yes
build_make_cmd x86-fe "fe" 1
assert_has "services: list"             '--optional-services "akkoma games tube"'
assert_has "services: games opt-in"     "--enable-games"
assert_has "services: tor rides along"  "--with-tor"
assert_one_flags "services"

# explicit NONE (every user-level slug pruned) vs untouched (builder default)
reset_opts; OPT_SERVICES="none"
build_make_cmd x86-pki "pki" 1
assert_has "services none: empty list"  '--optional-services ""'
assert_not "services none: no games"    "--enable-games"
reset_opts
build_make_cmd x86-pki "pki" 1
assert_not "services default: no flag"  "--optional-services"

# checklist<->lone-toggle consistency: character-studio in the LIST implies the toggle
reset_opts; OPT_SERVICES="akkoma,character-studio" OPT_CHARACTER_STUDIO=yes
build_make_cmd x86-fe "fe" 1
assert_has "charstudio: in list"        "character-studio"
assert_one_flags "charstudio"
# legacy conf (toggle only, checklist never touched) still threads --with-character-studio
reset_opts; OPT_CHARACTER_STUDIO=yes
build_make_cmd x86-fe "fe" 1
assert_has "charstudio legacy: flag"    "--with-character-studio"
assert_not "charstudio legacy: no list" "--optional-services"

# services_sync_charstudio: the lone toggle edits a SET checklist (both ways)
OPT_SERVICES="akkoma"; OPT_CHARACTER_STUDIO=yes; services_sync_charstudio
assert_eq  "sync: toggle-on adds slug"  "${OPT_SERVICES}" "akkoma,character-studio"
OPT_CHARACTER_STUDIO=no; services_sync_charstudio
assert_eq  "sync: toggle-off removes"   "${OPT_SERVICES}" "akkoma"
OPT_SERVICES="character-studio"; OPT_CHARACTER_STUDIO=no; services_sync_charstudio
assert_eq  "sync: last slug -> none"    "${OPT_SERVICES}" "none"
OPT_SERVICES=""; OPT_CHARACTER_STUDIO=yes; services_sync_charstudio
assert_eq  "sync: untouched stays"      "${OPT_SERVICES}" ""

# ── edge-AI knobs: GPU roles opt in; edge_ai role is always-on ──────────────────
reset_opts; OPT_X86_EDGE_AI=yes OPT_EDGE_AI_RUNTIME=vllm OPT_EDGE_AI_MODELS="llama3.2:3b,nomic-embed-text"
build_make_cmd x86-be+gpu "gpu" 1
assert_has "edge-ai gpu: with"          "--with-edge-ai"
assert_has "edge-ai gpu: runtime"       "--edge-ai-runtime vllm"
assert_has "edge-ai gpu: models"        "--edge-ai-models llama3.2:3b,nomic-embed-text"
assert_one_flags "edge-ai gpu"
reset_opts; OPT_EDGE_AI_MODEL_DEFAULT="llama3.2:3b"
build_make_cmd x86-edge_ai "edge" 1
assert_has "edge-ai role: default model" "--edge-ai-model-default llama3.2:3b"
assert_not "edge-ai role: no --with"    "--with-edge-ai"

# ── standalone desktop: media label, home, branding, installer UI, extra flags ──
reset_opts
OPT_SA_GPU=nvidia OPT_SA_MEDIA_LABEL=DATA OPT_SA_AIDE=yes
OPT_HOME_MODE=adopt OPT_HOME_DEVICE=LABEL=home OPT_HOME_ENCRYPTED=yes OPT_HOME_SEED=stack
OPT_HOME_ARCHIVE=/tmp/home.tar.zst OPT_BR_WALLPAPER=/tmp/wall.png OPT_BR_ACCENT='#00ff88'
OPT_INSTALLER_UI=all OPT_EXTRA_FLAGS="--kernel-builtin --distdir /media/dist"
build_make_cmd x86-standalone-thick "thick" 1
assert_has "sa: gpu driver"             "--gpu-driver nvidia"
assert_has "sa: media label"            "--media-label DATA"
assert_has "sa: aide"                   "--with-aide"
assert_has "sa: home mode"              "--home-mode adopt"
assert_has "sa: home device"            "--home-device LABEL=home"
assert_has "sa: home encrypted"         "--home-encrypted"
assert_has "sa: home seed"              "--home-seed-code stack"
assert_has "sa: home archive"           "--include-home-archive /tmp/home.tar.zst"
assert_has "sa: wallpaper"              "--wallpaper /tmp/wall.png"
assert_has "sa: accent"                 "--accent-color #00ff88"
assert_has "sa: installer ui"           "--installer-ui all"
assert_has "sa: extra flags verbatim"   "--kernel-builtin --distdir /media/dist"
assert_not "sa: no cluster services"    "--optional-services"
assert_not "sa: extra NOT in IMG_FLAGS" "IMG_FLAGS="
assert_one_flags "sa"

# media OFF suppresses the label (and emits --no-media-data)
reset_opts; OPT_SA_MEDIA=no OPT_SA_MEDIA_LABEL=DATA
build_make_cmd x86-standalone-thin "thin" 1
assert_has "sa media off: no-media-data" "--no-media-data"
assert_not "sa media off: label gone"   "--media-label"

# home provisioning reaches the tailnet CLIENT desktops, not the cluster nodes
reset_opts; OPT_HOME_MODE=restore OPT_HOME_BACKUP=auto
build_make_cmd x86-laptop "laptop" 1
assert_has "client: home mode"          "--home-mode restore"
assert_has "client: home backup"        "--home-backup auto"
build_make_cmd x86-pki "pki" 1
assert_not "cluster: no home flags"     "--home-mode"

# ── UNAFFILIATED standalone desktop: plain Gentoo, ZERO Snapdragon affiliation ──
# The role PRESETS the neutral identity builder-side and HARD-ERRORS on any
# brand/branding/bundle-source/seed-code flag, so the menu channel must emit the
# x86-standalone-unaffiliated target + the generic desktop options ONLY. The trap:
# OPT_SA_THEME's persisted default is 'boogiepop' (reset_opts leaves it there) and
# a branded run can leave OPT_BRAND/OPT_BR_*/OPT_HOME_SEED behind in menu.conf —
# none of them may leak into this target's argv.
reset_opts   # note: OPT_SA_THEME stays at its boogiepop default on purpose
OPT_SA_USER=alice OPT_SA_GPU=nvidia OPT_SA_KEYFILE=boot OPT_SA_YUBIKEY=login
OPT_HOME_MODE=create OPT_HOME_SEED=stack        # seed left over from a branded run
OPT_BRAND=acme OPT_BR_WALLPAPER=/tmp/wall.png   # brand/branding leftovers too
OPT_EXTRA_FLAGS="--compress"
build_make_cmd x86-standalone-unaffiliated "unaff" 1
assert_eq  "unaff: make target"         "${RUN_MAKE[0]}" "x86-standalone-unaffiliated"
assert_not "unaff: no --theme (boogiepop default suppressed)" "--theme"
assert_not "unaff: no BRAND= profile"   "BRAND="
assert_not "unaff: no --brand"          "--brand"
assert_not "unaff: no --bundle-source"  "--bundle-source"
assert_not "unaff: no --home-seed-code" "--home-seed-code"
assert_not "unaff: no --wallpaper"      "--wallpaper"
assert_has "unaff: local user collected" "--local-user alice"
assert_has "unaff: gpu driver"          "--gpu-driver nvidia"
assert_has "unaff: unlock keyfile"      "--unlock-keyfile boot"
assert_has "unaff: unlock yubikey"      "--unlock-yubikey login"
assert_has "unaff: home mode (generic) survives" "--home-mode create"
assert_has "unaff: extra flags verbatim" "--compress"
assert_one_flags "unaff"
# the branded thick sibling is UNCHANGED by the gating: the very same options
# still emit --theme/--home-seed-code/BRAND= there
build_make_cmd x86-standalone-thick "thick sibling" 1
assert_has "thick sibling: theme intact" "--theme boogiepop"
assert_has "thick sibling: seed intact" "--home-seed-code stack"
assert_has "thick sibling: brand intact" "BRAND=acme"
assert_has "thick sibling: wallpaper intact" "--wallpaper /tmp/wall.png"

# ── extra flags ride IMG_FLAGS on the targets without STANDALONE_FLAGS ──────────
reset_opts; OPT_IMGFLAGS="--no-iso" OPT_EXTRA_FLAGS="--enable-wifi"
build_make_cmd rpi-frontend "pi fe" 1
assert_has "rpi: extra via IMG_FLAGS"   "IMG_FLAGS=--no-iso --enable-wifi"
assert_not "rpi: no STANDALONE_FLAGS"   "STANDALONE_FLAGS="
build_make_cmd x86-be "be" 1
assert_has "x86: imgflags plain"        "IMG_FLAGS=--no-iso"
assert_not "x86: extra NOT doubled"     "IMG_FLAGS=--no-iso --enable-wifi"
assert_has "x86: extra via STANDALONE"  "STANDALONE_FLAGS=--enable-wifi"
# fleet targets (heterogeneous roles/arches): extra-flags has no single safe
# destination, so it's excluded from IMG_FLAGS the same way build-all is —
# same class of gap as the RESUME/PENTEST fleet-gating bug above.
build_make_cmd build-everything "everything" 20
assert_has "everything: imgflags plain" "IMG_FLAGS=--no-iso"
assert_not "everything: extra NOT doubled" "IMG_FLAGS=--no-iso --enable-wifi"

# ── frite: board + flavor + desktop make-vars ───────────────────────────────────
reset_opts; OPT_FRITE_BOARD=le-potato OPT_FRITE_FLAVOR=live OPT_FRITE_DESKTOP=none
build_make_cmd frite "frite" 1
assert_has "frite: board"               "FRITE_BOARD=le-potato"
assert_has "frite: flavor"              "FRITE_FLAVOR=live"
assert_has "frite: desktop"             "FRITE_DESKTOP=none"

# ── jetson (EXPERIMENTAL): jetson-% targets — OWN axes as make-vars; the x86 ────
# knobs (--optional-services/--with-tor/edge-AI model-library/branding/installer
# UI) are x86-only flags build-jetson-stage4.sh rejects, so build_make_cmd must
# NOT emit them for a jetson target. Only the verbatim extra-flags escape hatch
# rides STANDALONE_FLAGS (the Makefile jetson/jetson-% targets append it).
reset_opts; OPT_EDGE_AI_MODELS="llama3.2:3b" OPT_TOR_ONION=yes OPT_SERVICES="akkoma,tuwunel,phpbb"
build_make_cmd jetson-edge_ai "jetson edge" 1
assert_eq  "jetson: target first"       "${RUN_MAKE[0]}" "jetson-edge_ai"
assert_has "jetson: board make-var"     "JETSON_BOARD=orin-nano"
assert_has "jetson: kernel make-var"    "JETSON_KERNEL_FLAVOR=mainline"
assert_not "jetson edge_ai: no models"  "--edge-ai-models"
assert_not "jetson edge_ai: no --with"  "--with-edge-ai"
assert_not "jetson: no services list"   "--optional-services"
assert_not "jetson: no tor"             "--with-tor"
assert_one_flags "jetson edge_ai"
reset_opts; OPT_X86_EDGE_AI=yes OPT_JETSON_BOARD=orin-nx-16gb
build_make_cmd jetson-gpu-host "jetson gpu" 1
assert_has "jetson gpu-host: board"     "JETSON_BOARD=orin-nx-16gb"
assert_not "jetson gpu-host: no opt-in" "--with-edge-ai"
build_make_cmd jetson-full "jetson full" 1
assert_not "jetson full: no opt-in"     "--with-edge-ai"
reset_opts; OPT_BR_WALLPAPER=/tmp/wall.png OPT_INSTALLER_UI=all
build_make_cmd jetson-desktop "jetson desktop" 1
assert_not "jetson desktop: no edge-ai" "--with-edge-ai"
assert_not "jetson desktop: no branding" "--wallpaper"
assert_not "jetson desktop: no inst-ui" "--installer-ui"
assert_one_flags "jetson desktop"
# the escape hatch is the ONLY flag channel for jetson (and x86 flags never leak in)
reset_opts; OPT_EXTRA_FLAGS="--enable-wifi --img-size 20480" OPT_SERVICES="akkoma"
build_make_cmd jetson-edge_ai "jetson extra" 1
assert_has "jetson: extra via STANDALONE" "STANDALONE_FLAGS=--enable-wifi --img-size 20480"
assert_not "jetson: extra NOT in IMG_FLAGS" "IMG_FLAGS="
assert_not "jetson: services still gone" "--optional-services"
assert_one_flags "jetson extra"

# ── env/brand/root-login threading unchanged ────────────────────────────────────
reset_opts; OPT_ENV=prod OPT_BRAND=acme OPT_DOMAIN=acme.example OPT_ROOT_LOGIN=prohibit-password OPT_PATH=native
build_make_cmd x86-be "be" 1
assert_has "env: prod"                  "ENV=prod"
assert_has "brand"                      "BRAND=acme"
assert_has "domain"                     "DOMAIN=acme.example"
assert_has "root login"                 "PERMIT_ROOT_LOGIN=prohibit-password"
assert_has "native"                     "NATIVE=1"

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]

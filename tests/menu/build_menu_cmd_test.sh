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
    OPT_EDGE_AI_TTS=no
    OPT_TOR_ONION=no OPT_CHARACTER_STUDIO=no OPT_SERVICES="" OPT_INSTALLER_UI=""
    OPT_EXTRA_FLAGS=""
    OPT_BR_WALLPAPER="" OPT_BR_GRUB_BG="" OPT_BR_LOGIN_BG="" OPT_BR_LOGO=""
    OPT_BR_ACCENT="" OPT_BR_SCHEME=""
    OPT_HOME_MODE="" OPT_HOME_DEVICE="" OPT_HOME_BACKUP="" OPT_HOME_ENCRYPTED=no
    OPT_HOME_SEED="" OPT_HOME_ARCHIVE=""
    OPT_FRITE_BOARD=la-frite OPT_FRITE_FLAVOR=both OPT_FRITE_DESKTOP=light
    OPT_RPI_BOARD=rpi5
    OPT_SA_GPU=all-free OPT_SA_STEAM=native OPT_SA_MEDIA=yes OPT_SA_USER=snap
    OPT_SA_KEYFILE=none OPT_SA_YUBIKEY=none OPT_SA_THEME=boogiepop OPT_SA_PROXY=yes
    OPT_SA_SNORT=yes OPT_SA_AIDE=no OPT_SA_KBUILTIN=no OPT_SA_EGRESS=""
    OPT_SA_MEDIA_LABEL="" OPT_ROOT_LOGIN=no SA_LOCAL_PASS="" SA_LUKS_PASS=""
    ARM_LOCAL_PASS="" ARM_LUKS_PASS=""
    OPT_JETSON_BOARD=orin-nano OPT_JETSON_KFLAVOR=mainline
    OPT_ORANGEPI5_BOARD=orange-pi-5-plus OPT_ORANGEPI5_FLAVOR=both OPT_ORANGEPI5_FLEET=no
    OPT_ORANGEPIZERO2_FLAVOR=both
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

# edge-ai-tts: CPU-only, NO edge-ai dependency — must reach argv on a NON-GPU
# cluster role (unlike edge-ai-analysis, which is scoped to the GPU-target case).
reset_opts; OPT_EDGE_AI_TTS=yes
build_make_cmd x86-fe "fe" 1
assert_has "edge-ai-tts: flag on non-GPU role" "--with-edge-ai-tts"
assert_not "edge-ai-tts: no edge-ai fold" "--with-edge-ai "
assert_one_flags "edge-ai-tts"
reset_opts
build_make_cmd x86-fe "fe" 1
assert_not "edge-ai-tts: off by default"  "--with-edge-ai-tts"

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
assert_has "unaff: local user collected" "--local-user 'alice'"
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
# rpi-<role> (single-role) moved to the STANDALONE_FLAGS channel alongside
# x86-*/jetson-*/frite (Phase 1 of the standalone-ARM track: --standalone/
# --local-user/--local-pass need somewhere to ride); the rpi FLEET target
# (multiple roles per build) stays on IMG_FLAGS, same reasoning as build-all.
reset_opts; OPT_IMGFLAGS="--no-iso" OPT_EXTRA_FLAGS="--enable-wifi"
build_make_cmd rpi-frontend "pi fe" 1
assert_has "rpi-role: imgflags plain"      "IMG_FLAGS=--no-iso"
assert_not "rpi-role: extra NOT doubled"   "IMG_FLAGS=--no-iso --enable-wifi"
assert_has "rpi-role: extra via STANDALONE" "STANDALONE_FLAGS=--enable-wifi"
build_make_cmd rpi "fleet" 3
assert_has "rpi fleet: extra via IMG_FLAGS" "IMG_FLAGS=--no-iso --enable-wifi"
assert_not "rpi fleet: no STANDALONE_FLAGS" "STANDALONE_FLAGS="
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

# ── ARM_LOCAL_PASS/ARM_LUKS_PASS: masked secrets fold into STANDALONE_FLAGS ──────
# Regression coverage for a real bug: rpi5/frite/jetson/orangepi5/orangepizero2
# had NO masked entry point for --local-pass/--luks-pass at all (unlike x86's
# standalone_screen()) — the only reachable path was typing them into the
# unmasked, PERSISTED "Extra builder flags" field (OPT_EXTRA_FLAGS, written to
# ${CONF_FILE} in plaintext by save_conf on every save). arm_secrets_prompt()
# now collects them into ARM_LOCAL_PASS/ARM_LUKS_PASS (never persisted — reset_opts
# above and save_conf both exclude them, exactly like SA_LOCAL_PASS/SA_LUKS_PASS),
# and _arm_standalone_flags() folds them into STANDALONE_FLAGS ahead of the
# freeform escape hatch (which can still override, same ordering as x86's own
# `bf` string). Every value is wrapped by _shell_quote() (single-quoted, plain
# alnum values just get a harmless quote pair) — see the metachar-injection
# block further below for why.
reset_opts; ARM_LOCAL_PASS="Sup3rSecret!" ARM_LUKS_PASS="Unlock123"
build_make_cmd rpi-desktop "pi desktop, arm secrets" 1
assert_has "rpi-role: ARM_LOCAL_PASS threads"   "--local-pass 'Sup3rSecret!'"
assert_has "rpi-role: ARM_LUKS_PASS threads"    "--luks-pass 'Unlock123'"
assert_one_flags "rpi-role: arm secrets"
build_make_cmd frite "frite, arm secrets" 1
assert_has "frite: ARM_LOCAL_PASS threads"      "--local-pass 'Sup3rSecret!'"
build_make_cmd jetson-desktop "jetson desktop, arm secrets" 1
assert_has "jetson-role: ARM_LOCAL_PASS threads" "--local-pass 'Sup3rSecret!'"
build_make_cmd orangepi5 "orangepi5, arm secrets" 1
assert_has "orangepi5: ARM_LOCAL_PASS threads"  "--local-pass 'Sup3rSecret!'"
build_make_cmd orangepizero2 "orangepizero2, arm secrets" 1
assert_has "orangepizero2: ARM_LOCAL_PASS threads" "--local-pass 'Sup3rSecret!'"

# ordering: ARM_LOCAL_PASS/ARM_LUKS_PASS come BEFORE the freeform extra-flags
# field, so an operator can still override via Extra builder flags if needed —
# same convention as x86's `bf` string (extra flags always LAST).
reset_opts; ARM_LOCAL_PASS="Sup3rSecret!" OPT_EXTRA_FLAGS="--enable-wifi"
build_make_cmd rpi-desktop "pi desktop, arm secrets + extra" 1
assert_has "rpi-role: combined secrets+extra" "STANDALONE_FLAGS=--local-pass 'Sup3rSecret!' --enable-wifi"

# a plain build with no secrets set must NOT emit an empty/bogus --local-pass —
# STANDALONE_FLAGS should only appear when there's something to say.
reset_opts
build_make_cmd rpi-desktop "pi desktop, no secrets" 1
assert_not "rpi-role: no secrets -> no local-pass" "--local-pass"
assert_not "rpi-role: no secrets -> no luks-pass"  "--luks-pass"

# ── metacharacter-laden secrets: real command-injection-shaped regression ───────
# Confirmed defect: a password/passphrase containing shell metacharacters
# (space, single quote, `;`, `$()`, backticks) previously flowed UNQUOTED into
# STANDALONE_FLAGS, which the Makefile then re-expands into a real shell
# command line (native execution AND, before the Docker-dispatch fix, a second
# hazard there too) — an ordinary strong/diceware password could execute
# arbitrary shell text. _shell_quote() now wraps every secret in single quotes
# (escaping any embedded quote as '\''), so the composed STANDALONE_FLAGS text
# must contain the value byte-for-byte, self-quoted, never bare.
reset_opts; ARM_LOCAL_PASS="pw; touch /tmp/pwned; echo done" ARM_LUKS_PASS='it'"'"'s a $(secret) `here`'
build_make_cmd rpi-desktop "pi desktop, metachar secrets" 1
assert_has "rpi-role: semicolon/cmdsub password self-quoted" \
    "--local-pass 'pw; touch /tmp/pwned; echo done'"
assert_has "rpi-role: embedded-quote passphrase escaped"     \
    "--luks-pass 'it'\\''s a \$(secret) \`here\`'"

reset_opts; SA_LOCAL_PASS="pw; touch /tmp/pwned; echo done" OPT_SA_USER="it's-alice"
build_make_cmd x86-standalone-thin "x86 standalone, metachar secrets" 1
assert_has "x86: semicolon/cmdsub password self-quoted" \
    "--local-pass 'pw; touch /tmp/pwned; echo done'"
assert_has "x86: embedded-quote username escaped" \
    "--local-user 'it'\\''s-alice'"

# ── _redacted_run_make: console/log preview fully masks multi-word secrets ──────
# Regression coverage for a real bug: the OLD redaction was a token-based regex
# that only masked the FIRST whitespace-delimited word after --local-pass/
# --luks-pass, leaving the rest of a multi-word (diceware-style) passphrase —
# and a dangling stray quote — printed in the clear in both the console
# "launching: ..." line and the persistent per-run log file (which the menu's
# own "Log tail" feature re-displays). launch_build() was also previously the
# ONLY caller of this logic and was never exercised by this test file at all;
# _redacted_run_make() is now a standalone, directly testable function.
redacted="$(_redacted_run_make "rpi-desktop" "WORK_DIR=/out" \
    "STANDALONE_FLAGS=--standalone --local-pass correct horse battery staple --luks-pass 'unlock me too' --enable-wifi")"
case "${redacted}" in
    *"correct horse battery staple"*|*"unlock me too"*) _bad "redact: multi-word secret leaked in ${redacted}" ;;
    *"STANDALONE_FLAGS=<redacted>"*) _ok ;;
    *) _bad "redact: placeholder missing from ${redacted}" ;;
esac
case "${redacted}" in
    *"rpi-desktop"*"WORK_DIR=/out"*) _ok ;;
    *) _bad "redact: non-secret elements must survive untouched: ${redacted}" ;;
esac
# no secret flags present -> element passes through completely untouched
redacted="$(_redacted_run_make "rpi-desktop" "STANDALONE_FLAGS=--enable-wifi --no-iso")"
assert_eq "redact: no-secret element untouched" "${redacted}" "rpi-desktop STANDALONE_FLAGS=--enable-wifi --no-iso"

# ── rpi: --board axis (Phase 6, Pi 4 support) — RPI_BOARD make-var threaded to ──
# BOTH rpi-% (single-role) and the bare 'rpi' 3-role fleet target, so a board
# picked in single_role_screen()'s Pi-board picker survives a switch to the
# fleet menu entry instead of silently reverting to the rpi5 default.
reset_opts
build_make_cmd rpi-desktop "pi desktop default board" 1
assert_has "rpi-role: default board"    "RPI_BOARD=rpi5"
build_make_cmd rpi "fleet default board" 3
assert_has "rpi fleet: default board"   "RPI_BOARD=rpi5"

reset_opts; OPT_RPI_BOARD=rpi4
build_make_cmd rpi-backend "pi be, rpi4" 1
assert_has "rpi-role: rpi4 board"       "RPI_BOARD=rpi4"
assert_has "rpi-role: role intact"      "rpi-backend"
build_make_cmd rpi "fleet, rpi4" 3
assert_has "rpi fleet: rpi4 board"      "RPI_BOARD=rpi4"

# --board rpi3 (Phase 8, Pi 3 support) — DESKTOP-ONLY (the builder hard-errors
# on any other role), so the realistic single-role invocation is rpi-desktop,
# not rpi-backend. Threading itself (RPI_BOARD make-var composition) is
# role-agnostic here — this menu layer doesn't pre-validate the role/board
# combo (the builder's hard-error is the authoritative safety net) — mirrored
# for both the single-role AND fleet targets, same as rpi4 above.
reset_opts; OPT_RPI_BOARD=rpi3
build_make_cmd rpi-desktop "pi desktop, rpi3" 1
assert_has "rpi-role: rpi3 board"       "RPI_BOARD=rpi3"
assert_has "rpi-role: role intact"      "rpi-desktop"
build_make_cmd rpi "fleet, rpi3" 3
assert_has "rpi fleet: rpi3 board"      "RPI_BOARD=rpi3"

# x86-*/frite/jetson-* targets must NEVER pick up RPI_BOARD (it is meaningless
# there) — guards against a careless glob widening the rpi-* match above.
reset_opts; OPT_RPI_BOARD=rpi4
build_make_cmd x86-be "be" 1
assert_not "x86: no RPI_BOARD leak"     "RPI_BOARD="
build_make_cmd frite "frite" 1
assert_not "frite: no RPI_BOARD leak"   "RPI_BOARD="
build_make_cmd jetson-edge_ai "jetson" 1
assert_not "jetson: no RPI_BOARD leak"  "RPI_BOARD="

# ── frite: board + flavor + desktop make-vars ───────────────────────────────────
reset_opts; OPT_FRITE_BOARD=le-potato OPT_FRITE_FLAVOR=live OPT_FRITE_DESKTOP=none
build_make_cmd frite "frite" 1
assert_has "frite: board"               "FRITE_BOARD=le-potato"
assert_has "frite: flavor"              "FRITE_FLAVOR=live"
assert_has "frite: desktop"             "FRITE_DESKTOP=none"

# ── orangepi5 (EXPERIMENTAL): board + flavor make-vars, no --role/--desktop axis ─
reset_opts; OPT_ORANGEPI5_BOARD=orange-pi-5 OPT_ORANGEPI5_FLAVOR=live
build_make_cmd orangepi5 "orangepi5" 1
assert_eq  "orangepi5: target"           "${RUN_MAKE[0]}" "orangepi5"
assert_has "orangepi5: board"            "ORANGEPI5_BOARD=orange-pi-5"
assert_has "orangepi5: flavor"           "ORANGEPI5_FLAVOR=live"
reset_opts; OPT_ORANGEPI5_BOARD=orange-pi-5-plus OPT_ORANGEPI5_FLAVOR=both
build_make_cmd orangepi5 "orangepi5 default" 1
assert_has "orangepi5: default board"    "ORANGEPI5_BOARD=orange-pi-5-plus"
assert_has "orangepi5: default flavor"   "ORANGEPI5_FLAVOR=both"
# x86-*/frite/jetson-*/rpi-* targets must NEVER pick up ORANGEPI5_BOARD/FLAVOR —
# guards against a careless glob widening the orangepi5-only threading above.
reset_opts; OPT_ORANGEPI5_BOARD=orange-pi-5
build_make_cmd x86-be "be" 1
assert_not "x86: no ORANGEPI5_BOARD leak" "ORANGEPI5_BOARD="
build_make_cmd frite "frite" 1
assert_not "frite: no ORANGEPI5_BOARD leak" "ORANGEPI5_BOARD="
build_make_cmd jetson-edge_ai "jetson" 1
assert_not "jetson: no ORANGEPI5_BOARD leak" "ORANGEPI5_BOARD="

# ── orangepizero2 (EXPERIMENTAL): flavor make-var only — no --role/--desktop AND
# no --board axis at all (a single board, unlike Frite/Orange-Pi-5's board
# tables — see specs-orangepi-zero2/README.md) ──────────────────────────────
reset_opts; OPT_ORANGEPIZERO2_FLAVOR=live
build_make_cmd orangepizero2 "orangepizero2" 1
assert_eq  "orangepizero2: target"          "${RUN_MAKE[0]}" "orangepizero2"
assert_has "orangepizero2: flavor"          "ORANGEPIZERO2_FLAVOR=live"
reset_opts; OPT_ORANGEPIZERO2_FLAVOR=both
build_make_cmd orangepizero2 "orangepizero2 default" 1
assert_has "orangepizero2: default flavor"  "ORANGEPIZERO2_FLAVOR=both"
# x86-*/frite/jetson-* targets must NEVER pick up ORANGEPIZERO2_FLAVOR — guards
# against a careless glob widening the orangepizero2-only threading above.
reset_opts; OPT_ORANGEPIZERO2_FLAVOR=live
build_make_cmd x86-be "be" 1
assert_not "x86: no ORANGEPIZERO2_FLAVOR leak" "ORANGEPIZERO2_FLAVOR="
build_make_cmd frite "frite" 1
assert_not "frite: no ORANGEPIZERO2_FLAVOR leak" "ORANGEPIZERO2_FLAVOR="
build_make_cmd jetson-edge_ai "jetson" 1
assert_not "jetson: no ORANGEPIZERO2_FLAVOR leak" "ORANGEPIZERO2_FLAVOR="

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

# ── MDM phone screen (phone_screen/_phone_run) — WS-MENU additive block ──
# The phone wizard is a NON-BUILD choice (like Local Docker mesh): it must never
# touch build_make_cmd, never persist state (no OPT_PHONE_*, save_conf untouched),
# run its driver FOREGROUND only, and move the auth key via a chmod-600 mktemp
# file under STATE_DIR that is shredded after the run.
MENU_SH="${REPO_DIR}/scripts/build-menu.sh"
_fail() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1" >&2; }
# assert_grep NAME ERE FILE / assert_ngrep NAME ERE FILE — file-shape assertions
assert_grep()  { grep -qE -- "$2" "$3" && _ok || _fail "$1: /$2/ missing from $3"; }
assert_ngrep() { grep -qE -- "$2" "$3" && _fail "$1: /$2/ unexpectedly present in $3" || _ok; }

# the four GOLDEN mode_screen items stay byte-identical (same opening-item-shape
# anchor the build-matrix TAXO bucket uses), and the phone item joins them as a
# REAL pickable item — not merely prose.
assert_grep "taxo: meshnode golden item intact"   '^[[:space:]]*meshnode[[:space:]]+"Mesh node — build server node image\(s\) for a mesh on dedicated hardware"'                          "${MENU_SH}"
assert_grep "taxo: localmesh golden item intact"  '^[[:space:]]*localmesh[[:space:]]+"Local Docker mesh — run a mesh on THIS machine in Docker \(no image built\)"'                        "${MENU_SH}"
assert_grep "taxo: client golden item intact"     '^[[:space:]]*client[[:space:]]+"Mesh desktop client — a branded desktop that JOINS an existing mesh \(tailnet \+ SSO\)"'                "${MENU_SH}"
assert_grep "taxo: standalone golden item intact" '^[[:space:]]*standalone[[:space:]]+"Standalone Gentoo desktop — hardened personal / UNAFFILIATED desktop \(no mesh/SSO\)"'              "${MENU_SH}"
assert_grep "phone: opening item present"         '^[[:space:]]*phone[[:space:]]+"MDM phone '  "${MENU_SH}"
assert_grep "phone: routed to phone_screen"       '^[[:space:]]*phone\)[[:space:]]+phone_screen '     "${MENU_SH}"

# no persistence: no OPT_PHONE_* anywhere, and the phone functions never call
# save_conf / launch_build / setsid (foreground-only, function-local state).
assert_ngrep "phone: no OPT_PHONE_* state"        'OPT_PHONE' "${MENU_SH}"
phone_region="$(sed -n '/^phone_screen() {/,/^}/p' "${MENU_SH}"; sed -n '/^_phone_run() {/,/^}/p' "${MENU_SH}")"
case "${phone_region}" in
    *'--authkey-file'*) _ok ;;
    *) _fail "phone: region extraction vacuous (phone_screen/_phone_run not found)" ;;
esac
printf '%s' "${phone_region}" | grep -q 'setsid'       && _fail "phone: setsid in phone region (must run foreground)" || _ok
printf '%s' "${phone_region}" | grep -q 'launch_build' && _fail "phone: launch_build in phone region (must run foreground)" || _ok
printf '%s' "${phone_region}" | grep -q 'save_conf'    && _fail "phone: save_conf in phone region (state must stay function-local)" || _ok

# save_conf stays phone-free: a fresh save leaks no phone/auth-key material.
reset_opts; save_conf
grep -qiE 'phone|authkey|tskey' "${CONF_FILE}" && _fail "conf: phone/auth-key state leaked into menu.conf" || _ok

# ── _phone_run behavioural checks against a stub driver ────────────────────────
# The stub records its argv and, at CHILD runtime, the --authkey-file's content +
# mode — proving the secret travels by 0600 file only and is shredded afterwards.
PHONE_STUB_OUT="${SNAP_MENU_STATE}/phone-stub-out"; mkdir -p "${PHONE_STUB_OUT}"
export PHONE_STUB_OUT
SNAP_PHONE_WIZARD="${SNAP_MENU_STATE}/stub-phone-wizard.sh"
cat >"${SNAP_PHONE_WIZARD}" <<'EOSTUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${PHONE_STUB_OUT:?}/argv"
prev=""
for a in "$@"; do
    if [ "${prev}" = "--authkey-file" ]; then
        cat -- "${a}" >"${PHONE_STUB_OUT}/key-content" 2>/dev/null
        stat -c '%a' -- "${a}" >"${PHONE_STUB_OUT}/key-mode" 2>/dev/null
        printf '%s' "${a}" >"${PHONE_STUB_OUT}/key-path"
    fi
    prev="${a}"
done
exit "${PHONE_STUB_RC:-0}"
EOSTUB
chmod +x "${SNAP_PHONE_WIZARD}"

# all settings set: full deterministic argv (auth key OFF the argv, file at tail)
PHONE_SECRET='tskey-auth-Sup3r Secret!'
_phone_run enroll "${PHONE_SECRET}" comet beta S1TEST "" "https://hs.example" admin </dev/null 2>/dev/null
assert_eq "phone run: argv (verb first, options in order, secret off-argv)" \
    "$(head -n -2 "${PHONE_STUB_OUT}/argv")" \
    "$(printf '%s\n' enroll --codename comet --channel beta --serial S1TEST --login-server https://hs.example --role admin)"
grep -qF -- "${PHONE_SECRET}" "${PHONE_STUB_OUT}/argv" && _fail "phone run: auth key leaked onto argv" || _ok
case "$(cat "${PHONE_STUB_OUT}/key-path")" in
    "${SNAP_MENU_STATE}"/phonekey.*) _ok ;;
    *) _fail "phone run: keyfile not under STATE_DIR: $(cat "${PHONE_STUB_OUT}/key-path")" ;;
esac
assert_eq "phone run: keyfile content is the secret" "$(cat "${PHONE_STUB_OUT}/key-content")" "${PHONE_SECRET}"
assert_eq "phone run: keyfile mode 600 at child runtime" "$(cat "${PHONE_STUB_OUT}/key-mode")" "600"
[ -e "$(cat "${PHONE_STUB_OUT}/key-path")" ] && _fail "phone run: keyfile survived (must be shredded)" || _ok

# nothing set: bare verb only — no empty/bogus flags, no --authkey-file
_phone_run status "" "" "" "" "" "" "" </dev/null 2>/dev/null
assert_eq "phone run: bare verb argv" "$(cat "${PHONE_STUB_OUT}/argv")" "status"

# keys-dir mode: --keys-dir threads; server/role stay driver-side (keys-dir files)
_phone_run detect "" "" stable "" "/tmp/pw-keys" "" "" </dev/null 2>/dev/null
assert_eq "phone run: keys-dir argv" "$(cat "${PHONE_STUB_OUT}/argv")" \
    "$(printf '%s\n' detect --channel stable --keys-dir /tmp/pw-keys)"

# a failing driver must not kill the sourced-menu shell (set -e is absent by design)
PHONE_STUB_RC=7 _phone_run status "" "" "" "" "" "" "" </dev/null 2>/dev/null
assert_eq "phone run: nonzero driver rc survives" "$?" "0"

# ── phone_screen(): drive its OWN choice-to-local-variable case block ───────────
# Finding #22 (tests-coverage): every _phone_run check above proves argv-building
# is correct GIVEN already-correct inputs — none of them ever go through
# phone_screen()'s own interactive `case "${choice}" in device) channel) serial)
# keys) server) authkey) role) ...` loop that turns menu picks into those inputs
# in the first place. A typo'd case label or a swapped/misassigned local there
# would slip straight past every check above undetected.

# #10 regression pin (static, source-text only): ui_password's DEFAULT-preserving
# contract on both the whiptail-cancel and non-TUI read-failure paths. Actually
# driving those paths live would require a real /dev/tty, which this offline
# suite must never touch (see ui_menu's own text fallback, which explicitly
# reads from /dev/tty, never stdin) — that's also why the walk below stubs
# ui_menu/ui_input/ui_password rather than feeding stdin into the real ones.
ui_password_body="$(sed -n '/^ui_password() {/,/^}/p' "${MENU_SH}")"
printf '%s' "${ui_password_body}" | grep -qF 'def="${3:-}"' \
    && _ok || _fail "ui_password: no DEFAULT (3rd) param — regressed #10's preserve-on-cancel contract"
printf '%s' "${ui_password_body}" | grep -qF '|| { printf '"'"'%s'"'"' "${def}"; return 0; }' \
    && _ok || _fail "ui_password: whiptail-cancel path no longer falls back to DEFAULT"
printf '%s' "${ui_password_body}" | grep -qF '|| val="${def}"' \
    && _ok || _fail "ui_password: non-TUI read-failure path no longer falls back to DEFAULT"

# Stub _phone_run (capture argv instead of exec'ing the driver) and ui_menu/
# ui_input/ui_password (one scripted-response QUEUE per function) then walk
# phone_screen through one full pass: device -> channel -> serial -> keys ->
# server -> authkey -> role -> plan -> back. Queue order mirrors exactly what
# phone_screen's loop is expected to call: the OUTER menu is asked once per
# field visited plus once for "plan" and once for "back" (11 calls total);
# `channel` and `role` also open a nested ui_menu of their own. Each queue is a
# newline-delimited FIFO FILE, not a bash array — phone_screen invokes these via
# command substitution ("$(ui_menu ...)"), which forks a SUBSHELL, so a pop that
# only mutated an in-memory array would vanish the instant that subshell exits
# and every call would silently re-read the same head element forever; a file
# pop (read the first line, then rewrite the file without it) survives the
# subshell boundary because it's a real filesystem mutation, not shell state.
# Runs AFTER the real _phone_run/ui_* checks above so it doesn't disturb them.
PHONE_SCREEN_ARGV="${SNAP_MENU_STATE}/phone-screen-argv"
_phone_run() { printf '%s\n' "$@" >"${PHONE_SCREEN_ARGV}"; }
_UI_MENU_Q="${SNAP_MENU_STATE}/ui-menu.q"
_UI_INPUT_Q="${SNAP_MENU_STATE}/ui-input.q"
_UI_PASSWORD_Q="${SNAP_MENU_STATE}/ui-password.q"
printf '%s\n' device channel beta serial keys server authkey role admin plan back >"${_UI_MENU_Q}"
printf '%s\n' comet S9PIXEL "" "https://hs.example.test"                          >"${_UI_INPUT_Q}"
printf '%s\n' "tskey-auth-Sup3r Secret!"                                          >"${_UI_PASSWORD_Q}"
_q_pop()      { head -n1 "$1"; sed -i '1d' "$1"; }
ui_menu()     { _q_pop "${_UI_MENU_Q}"; }
ui_input()    { _q_pop "${_UI_INPUT_Q}"; }
ui_password() { _q_pop "${_UI_PASSWORD_Q}"; }

phone_screen

# device/channel/serial/keys/server/authkey/role must each have landed in the
# right positional slot of the _phone_run call phone_screen made for "plan" —
# proving the case block's local-variable assignments are wired to the right
# fields (a swapped/typo'd case label would scramble this ordering), including
# a masked authkey with an embedded space to prove byte-exact capture.
expected_argv="$(printf '%s\n' plan "tskey-auth-Sup3r Secret!" comet beta S9PIXEL "" "https://hs.example.test" admin)"
assert_eq "phone_screen: captured _phone_run argv matches the driven field selections" \
    "$(cat "${PHONE_SCREEN_ARGV}" 2>/dev/null)" "${expected_argv}"
# every queued response must have actually been consumed — too few calls (a
# field silently skipped) leaves a nonzero-size leftover queue file.
[ -s "${_UI_MENU_Q}" ]     && _bad "phone_screen: ui_menu queue not fully consumed: $(cat "${_UI_MENU_Q}")"     || _ok
[ -s "${_UI_INPUT_Q}" ]    && _bad "phone_screen: ui_input queue not fully consumed: $(cat "${_UI_INPUT_Q}")"   || _ok
[ -s "${_UI_PASSWORD_Q}" ] && _bad "phone_screen: ui_password queue not fully consumed"                          || _ok

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]

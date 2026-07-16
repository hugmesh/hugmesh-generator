#!/usr/bin/env bash
# build-menu.sh — a console (ncurses/whiptail) front door for the image build.
#
# WHAT IT IS
#   An interactive terminal menu that drives the SAME `make` targets the rest of
#   the repo uses (build-all / rpi / x86 / omnibus / frite / clean / rebuild). It
#   adds nothing to the build engine — it just makes the knobs discoverable and
#   shows live progress. Because it dispatches through `make`, it works for BOTH
#   build paths with no extra logic: the default Docker builder image AND the
#   local NATIVE=1 Gentoo path (a single in-menu toggle flips NATIVE).
#
# THREE THINGS THE USER ASKED FOR, AND HOW THEY ARE MET
#   1. "progress indicators"            — a live monitor screen parses the build
#                                          log for emerge's "(X of Y)" package
#                                          counter and the per-role banners, and
#                                          draws progress bars + a log tail.
#   2. "quit without stopping builds"   — every build is launched DETACHED via
#                                          `setsid nohup ... </dev/null &`, in its
#                                          own session. Quitting the menu (or even
#                                          closing the terminal) leaves it running.
#   3. "brought up again with current   — on start the menu detects a build that
#       progress"                          is still running (its own, OR one you
#                                          launched by hand) and drops straight
#                                          into the live monitor for it.
#
# RENDERER
#   Uses whiptail (newt/ncurses) when a real TTY + whiptail are present; otherwise
#   falls back to a plain numbered-prompt menu so it still works inside the minimal
#   Docker builder image or a dumb terminal (set NO_TUI=1 to force the fallback).
#   The live monitor is plain ANSI either way (so it can offer "press q to leave
#   the build running", which a whiptail gauge cannot).
#
# RUN IT
#   ./scripts/build-menu.sh          # or:  make menu
#
# It is interactive, so it deliberately does NOT use `set -e`: a TUI runs many
# commands that return non-zero benignly (whiptail Cancel = 1, grep no-match = 1,
# a `read` timeout > 128). We keep -u/pipefail and handle every error explicitly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Colours (only when stderr is a TTY, matching scripts/_download-lib.sh) ──────
if [ -t 2 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
    C_BLD=$'\033[1m';  C_DIM=$'\033[2m';  C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_CYN=''; C_BLD=''; C_DIM=''; C_RST=''
fi
say()  { printf '%s[build-menu]%s %s\n' "${C_GRN}" "${C_RST}" "$*" >&2; }
warn() { printf '%s[build-menu] WARN:%s %s\n' "${C_YEL}" "${C_RST}" "$*" >&2; }
die()  { printf '%s[build-menu] ERROR:%s %s\n' "${C_RED}" "${C_RST}" "$*" >&2; exit 1; }

# Only draw UTF-8 box-art when the locale is actually UTF-8 (the minimal Docker
# builder image runs in C/POSIX, where box chars render as mojibake).
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]*) UTF8=1 ;; *) UTF8=0 ;; esac
# The Docker builder image tag (matches the Makefile's IMAGE), used to spot a
# docker-path build whose in-container scripts are invisible to host pgrep.
BUILDER_IMAGE="${IMAGE:-snapdragon-builder}"

# ── Persistent state (user-writable; WORK_DIR/out is often root-owned) ──────────
# Build state + saved menu options live here so a relaunch remembers your choices
# AND can re-attach to a running build. Kept OUT of WORK_DIR on purpose: a NATIVE
# build chowns WORK_DIR to root, which would make a state dir under it unwritable.
STATE_DIR="${SNAP_MENU_STATE:-${XDG_STATE_HOME:-${HOME}/.local/state}/snapdragon-build-menu}"
mkdir -p "${STATE_DIR}" 2>/dev/null || STATE_DIR="$(mktemp -d)"
PID_FILE="${STATE_DIR}/current.pid"
META_FILE="${STATE_DIR}/current.meta"
CONF_FILE="${STATE_DIR}/menu.conf"

# ── Build option defaults (overridable in the Options screen; persisted) ────────
OPT_WORK_DIR="${WORK_DIR:-${REPO_DIR}/out}"
OPT_JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
OPT_ENV="test"            # test | prod   (baked build environment)
OPT_PATH="docker"         # docker | native (native => make ... NATIVE=1)
OPT_BRAND=""              # brands/<name>.conf
OPT_DOMAIN=""             # overrides the brand's cluster domain
OPT_RESUME="no"           # yes => reuse existing sysroots (RESUME=true)
OPT_OMNIBUS="no"          # yes => add the x86 omnibus role (X86_OMNIBUS=1)
OPT_FRITE_FLEET="no"      # yes => fleet-build Frite too (full-fleet build only; FRITE=1)
OPT_JETSON_FLEET="no"     # yes => fleet-build Jetson too (full-fleet build only; JETSON=1)
OPT_ORANGEPI5_FLEET="no"  # yes => fleet-build Orange Pi 5 too (full-fleet build only; ORANGEPI5=1)
OPT_PENTEST="no"          # yes => run the OWASP pen-test after the build (PENTEST=1)
OPT_IMGFLAGS=""           # e.g. --no-iso (img only) / --no-img (iso only)
# ── Edge-AI inference service (GPU cluster roles: be+gpu / omnibus / edge_ai) ───
OPT_X86_EDGE_AI="no"          # yes => add the edge-ai service to be+gpu/omnibus (edge_ai role always has it)
OPT_EDGE_AI_RUNTIME="ollama"  # edge-ai inference runtime (ollama | vllm)
OPT_EDGE_AI_MODELS=""         # comma list of models to PRELOAD (empty = builder default)
OPT_EDGE_AI_MODEL_DEFAULT=""  # default model when an OpenAI request omits one (empty = builder default)
OPT_X86_EDGE_AI_ANALYSIS="no" # yes => also bake the edge-ai-analysis task API (image/log verdicts; separate image)
# edge-ai-tts is CPU-only + self-contained (NO edge-ai dependency, unlike
# edge-ai-analysis) — it is its own independent toggle, wired alongside Tor /
# Character Studio below (not gated to the GPU-target case).
OPT_EDGE_AI_TTS="no"          # yes => --with-edge-ai-tts: Piper TTS + viseme timeline (VN voice, separate image)
# ── Tor v3 onion (hidden) service — node-scoped optional, DEFAULT-OFF ──────────
OPT_TOR_ONION="no"            # yes => --with-tor: expose the in-cluster fe-gateway as a v3 .onion
# ── Character Studio (VN) frontend remote — OPTIONAL, DEFAULT-OFF (admin gate) ──
OPT_CHARACTER_STUDIO="no"     # yes => --with-character-studio: VN character-studio remote at /character-studio
# ── OPTIONAL services catalog (cluster roles; specs/cluster/optional-services.yaml) ─
# Comma list of user-level slugs {akkoma,tuwunel,phpbb,games,owncast,tube,
# character-studio}. Empty = builder default (akkoma tuwunel phpbb); the literal
# 'none' = EXPLICITLY none (=> --optional-services ""). The checklist supersedes
# the lone character-studio toggle above — the two are kept in sync both ways.
OPT_SERVICES=""
# ── Installer front-ends offered on the live ISO (--installer-ui) ───────────────
OPT_INSTALLER_UI=""           # cli | ncurses | calamares | all (empty = builder default)
# ── Extra builder flags — the verbatim escape hatch (all-options-in-all-menus) ──
# Appended AS-IS after --role on x86-*/jetson-* targets (via STANDALONE_FLAGS) and
# onto IMG_FLAGS for the other single-role targets, so ANY builder flag the menu
# has no widget for stays reachable.
OPT_EXTRA_FLAGS=""
# ── Advanced branding OVERRIDES (on top of the brand profile / --theme preset) ──
OPT_BR_WALLPAPER=""           # --wallpaper FILE
OPT_BR_GRUB_BG=""             # --grub-background FILE
OPT_BR_LOGIN_BG=""            # --login-background FILE
OPT_BR_LOGO=""                # --brand-logo FILE
OPT_BR_ACCENT=""              # --accent-color '#RRGGBB'
OPT_BR_SCHEME=""              # --color-scheme FILE.colors
# ── Home provisioning (standalone/client desktop roles) ─────────────────────────
OPT_HOME_MODE=""              # --home-mode create|adopt|archive|restore (empty = builder default)
OPT_HOME_DEVICE=""            # --home-device LABEL=…|UUID=…|/dev/… (adopt)
OPT_HOME_BACKUP=""            # --home-backup FILE|auto (restore)
OPT_HOME_ENCRYPTED="no"       # yes => --home-encrypted (per-user eCryptfs on top of LUKS2)
OPT_HOME_SEED=""              # --home-seed-code repos|stack|mesh (empty/none = builder default: none)
OPT_HOME_ARCHIVE=""           # --include-home-archive FILE (scripts/archive-home.sh tarball)
OPT_FRITE_BOARD="la-frite"
OPT_FRITE_FLAVOR="both"
OPT_FRITE_DESKTOP="light"     # light (LEAN LXDE desktop) | none (headless base)
# ── RPi board axis (build-rpi5-stage4.sh --board; ONE builder, all 3 boards) ──
OPT_RPI_BOARD="rpi5"          # rpi5 (DEFAULT, BCM2712/Cortex-A76) | rpi4 (BCM2711/Cortex-A72) | rpi3 (BCM2837/Cortex-A53, desktop-only)
# ── Jetson Orin (arm64 Tegra234; EXPERIMENTAL — hardware validation pending) ────
OPT_JETSON_BOARD="orin-nano"  # orin-nano | orin-nano-4gb | orin-nx-8gb | orin-nx-16gb
OPT_JETSON_KFLAVOR="mainline" # mainline (buildable; NO CUDA) | l4t (documented stub)
# ── Orange Pi 5 (arm64 Rockchip RK3588/RK3588S; EXPERIMENTAL — hardware
# validation pending) ────────────────────────────────────────────────────────
OPT_ORANGEPI5_BOARD="orange-pi-5-plus"   # orange-pi-5-plus (DEFAULT) | orange-pi-5
OPT_ORANGEPI5_FLAVOR="both"              # both (DEFAULT) | live | installer
# ── Orange Pi Zero 2 (arm64 Allwinner H616 HEADLESS APPLIANCE; EXPERIMENTAL —
# hardware validation pending). No board axis (one board) and no --desktop
# toggle (no desktop mode, ever — see specs-orangepi-zero2/README.md) — just
# --flavor. ───────────────────────────────────────────────────────────────
OPT_ORANGEPIZERO2_FLAVOR="both"          # both (DEFAULT) | live | installer
# ── Standalone hardened NVIDIA desktop options (NON-secret; persisted) ──────────
OPT_SA_GPU="all-free"         # all-free|nvidia-free|nvidia|amd-free|amd-pro|intel-free|intel-pro
OPT_SA_STEAM="native"         # native | flatpak | none
OPT_SA_MEDIA="yes"            # yes => media-data auto-detect (/media Vaults+Steam)
OPT_SA_USER="snap"            # local login user name
OPT_SA_KEYFILE="none"         # none | boot | login  (extra unlock factor: keyfile)
OPT_SA_YUBIKEY="none"         # none | boot | login  (extra unlock factor: FIDO2)
OPT_SA_THEME="boogiepop"      # branding theme preset (none | boogiepop | …)
OPT_SA_PROXY="yes"            # Squid+Privoxy+Firefox proxy stack (desktops; default on)
OPT_SA_SNORT="yes"            # Snort IDS (default on)
OPT_SA_AIDE="no"              # AIDE file-integrity IDS (opt-in)
OPT_SA_KBUILTIN="no"          # compile most of the kernel built-in (=y) vs modules
OPT_SA_EGRESS=""              # egress VPN conf path (wg .conf / .ovpn); empty = none
OPT_SA_MEDIA_LABEL=""         # --media-label: match the data device by FS LABEL (empty = content-scan)
# SECRETS are deliberately NOT persisted (never written to ${CONF_FILE}); they are
# prompted fresh each build and live only in these shell vars for the run.
SA_LOCAL_PASS=""              # local user password (plaintext, hashed by the builder)
SA_LUKS_PASS=""               # LUKS root-unlock passphrase (build-time only)
# Same masked/non-persisted contract as SA_LOCAL_PASS/SA_LUKS_PASS above, for the
# 5 platforms that gained --standalone in the standalone-ARM track (rpi5 desktop,
# frite, jetson desktop, orangepi5, orangepizero2) — none of them has a dedicated
# standalone_screen() of its own, so without this the ONLY reachable path for
# these secrets would be the unmasked, persisted "Extra builder flags" field
# (see arm_secrets_prompt() / _arm_standalone_flags() below).
ARM_LOCAL_PASS=""
ARM_LUKS_PASS=""
OPT_ROOT_LOGIN="no"       # no (DEFAULT, hardened) | prohibit-password | yes  (PERMIT_ROOT_LOGIN)

# Restore saved options from a previous session (best-effort; ignore a bad file).
# shellcheck disable=SC1090
[ -f "${CONF_FILE}" ] && source "${CONF_FILE}" 2>/dev/null || true

save_conf() {
    {
        printf 'OPT_WORK_DIR=%q\n'      "${OPT_WORK_DIR}"
        printf 'OPT_JOBS=%q\n'          "${OPT_JOBS}"
        printf 'OPT_ENV=%q\n'           "${OPT_ENV}"
        printf 'OPT_PATH=%q\n'          "${OPT_PATH}"
        printf 'OPT_BRAND=%q\n'         "${OPT_BRAND}"
        printf 'OPT_DOMAIN=%q\n'        "${OPT_DOMAIN}"
        printf 'OPT_RESUME=%q\n'        "${OPT_RESUME}"
        printf 'OPT_OMNIBUS=%q\n'       "${OPT_OMNIBUS}"
        printf 'OPT_FRITE_FLEET=%q\n'   "${OPT_FRITE_FLEET}"
        printf 'OPT_JETSON_FLEET=%q\n'  "${OPT_JETSON_FLEET}"
        printf 'OPT_ORANGEPI5_FLEET=%q\n' "${OPT_ORANGEPI5_FLEET}"
        printf 'OPT_PENTEST=%q\n'       "${OPT_PENTEST}"
        printf 'OPT_IMGFLAGS=%q\n'      "${OPT_IMGFLAGS}"
        printf 'OPT_X86_EDGE_AI=%q\n'   "${OPT_X86_EDGE_AI}"
        printf 'OPT_EDGE_AI_RUNTIME=%q\n' "${OPT_EDGE_AI_RUNTIME}"
        printf 'OPT_EDGE_AI_MODELS=%q\n'  "${OPT_EDGE_AI_MODELS}"
        printf 'OPT_EDGE_AI_MODEL_DEFAULT=%q\n' "${OPT_EDGE_AI_MODEL_DEFAULT}"
        printf 'OPT_X86_EDGE_AI_ANALYSIS=%q\n' "${OPT_X86_EDGE_AI_ANALYSIS}"
        printf 'OPT_EDGE_AI_TTS=%q\n'   "${OPT_EDGE_AI_TTS}"
        printf 'OPT_TOR_ONION=%q\n'     "${OPT_TOR_ONION}"
        printf 'OPT_CHARACTER_STUDIO=%q\n' "${OPT_CHARACTER_STUDIO}"
        printf 'OPT_SERVICES=%q\n'      "${OPT_SERVICES}"
        printf 'OPT_INSTALLER_UI=%q\n'  "${OPT_INSTALLER_UI}"
        printf 'OPT_EXTRA_FLAGS=%q\n'   "${OPT_EXTRA_FLAGS}"
        printf 'OPT_BR_WALLPAPER=%q\n'  "${OPT_BR_WALLPAPER}"
        printf 'OPT_BR_GRUB_BG=%q\n'    "${OPT_BR_GRUB_BG}"
        printf 'OPT_BR_LOGIN_BG=%q\n'   "${OPT_BR_LOGIN_BG}"
        printf 'OPT_BR_LOGO=%q\n'       "${OPT_BR_LOGO}"
        printf 'OPT_BR_ACCENT=%q\n'     "${OPT_BR_ACCENT}"
        printf 'OPT_BR_SCHEME=%q\n'     "${OPT_BR_SCHEME}"
        printf 'OPT_HOME_MODE=%q\n'     "${OPT_HOME_MODE}"
        printf 'OPT_HOME_DEVICE=%q\n'   "${OPT_HOME_DEVICE}"
        printf 'OPT_HOME_BACKUP=%q\n'   "${OPT_HOME_BACKUP}"
        printf 'OPT_HOME_ENCRYPTED=%q\n' "${OPT_HOME_ENCRYPTED}"
        printf 'OPT_HOME_SEED=%q\n'     "${OPT_HOME_SEED}"
        printf 'OPT_HOME_ARCHIVE=%q\n'  "${OPT_HOME_ARCHIVE}"
        printf 'OPT_FRITE_BOARD=%q\n'   "${OPT_FRITE_BOARD}"
        printf 'OPT_FRITE_FLAVOR=%q\n'  "${OPT_FRITE_FLAVOR}"
        printf 'OPT_FRITE_DESKTOP=%q\n' "${OPT_FRITE_DESKTOP}"
        printf 'OPT_RPI_BOARD=%q\n'     "${OPT_RPI_BOARD}"
        printf 'OPT_JETSON_BOARD=%q\n'  "${OPT_JETSON_BOARD}"
        printf 'OPT_JETSON_KFLAVOR=%q\n' "${OPT_JETSON_KFLAVOR}"
        printf 'OPT_ORANGEPI5_BOARD=%q\n'  "${OPT_ORANGEPI5_BOARD}"
        printf 'OPT_ORANGEPI5_FLAVOR=%q\n' "${OPT_ORANGEPI5_FLAVOR}"
        printf 'OPT_ORANGEPIZERO2_FLAVOR=%q\n' "${OPT_ORANGEPIZERO2_FLAVOR}"
        # Standalone-desktop NON-secret options (passwords are NEVER persisted).
        printf 'OPT_SA_GPU=%q\n'        "${OPT_SA_GPU}"
        printf 'OPT_SA_STEAM=%q\n'      "${OPT_SA_STEAM}"
        printf 'OPT_SA_MEDIA=%q\n'      "${OPT_SA_MEDIA}"
        printf 'OPT_SA_USER=%q\n'       "${OPT_SA_USER}"
        printf 'OPT_SA_KEYFILE=%q\n'    "${OPT_SA_KEYFILE}"
        printf 'OPT_SA_YUBIKEY=%q\n'    "${OPT_SA_YUBIKEY}"
        printf 'OPT_SA_THEME=%q\n'      "${OPT_SA_THEME}"
        printf 'OPT_SA_PROXY=%q\n'      "${OPT_SA_PROXY}"
        printf 'OPT_SA_SNORT=%q\n'      "${OPT_SA_SNORT}"
        printf 'OPT_SA_AIDE=%q\n'       "${OPT_SA_AIDE}"
        printf 'OPT_SA_KBUILTIN=%q\n'   "${OPT_SA_KBUILTIN}"
        printf 'OPT_SA_EGRESS=%q\n'     "${OPT_SA_EGRESS}"
        printf 'OPT_SA_MEDIA_LABEL=%q\n' "${OPT_SA_MEDIA_LABEL}"
        printf 'OPT_ROOT_LOGIN=%q\n'    "${OPT_ROOT_LOGIN}"
    } > "${CONF_FILE}" 2>/dev/null || true
}

# ── UI abstraction: whiptail when we can, a text prompt when we cannot ──────────
# Decide ONCE whether the rich renderer is usable: a real interactive TTY, a sane
# TERM, whiptail on PATH, and NO_TUI not set.
HAVE_TUI=0
if [ -z "${NO_TUI:-}" ] && [ -t 0 ] && [ -t 1 ] \
   && [ "${TERM:-dumb}" != dumb ] && command -v whiptail >/dev/null 2>&1; then
    HAVE_TUI=1
fi
WT_TITLE="Snapdragon Image Builder"

# ui_menu TITLE PROMPT  tag1 item1  tag2 item2 ...   -> echoes chosen tag, rc=1 on cancel
ui_menu() {
    local title="$1" prompt="$2"; shift 2
    if [ "${HAVE_TUI}" = 1 ]; then
        whiptail --title "${WT_TITLE} — ${title}" --notags --menu "${prompt}" \
            22 78 12 "$@" 3>&1 1>&2 2>&3
        return $?
    fi
    # Text fallback: number the (tag,item) pairs and read a choice.
    local -a tags=() items=(); local i
    while [ "$#" -ge 2 ]; do tags+=("$1"); items+=("$2"); shift 2; done
    printf '\n%s== %s ==%s\n' "${C_BLD}" "${title}" "${C_RST}" >&2
    printf '%b\n' "${prompt}" >&2
    for i in "${!items[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${items[$i]}" >&2; done
    printf '   q) back / cancel\n' >&2
    # Loop on INVALID input (a typo must not be mistaken for Cancel, which would
    # quit the program from the main menu); only 'q' / empty returns the cancel rc.
    local choice
    while true; do
        read -r -p "choice: " choice </dev/tty || return 1
        { [ "${choice}" = q ] || [ -z "${choice}" ]; } && return 1
        if [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#tags[@]}" ]; then
            printf '%s' "${tags[$((choice-1))]}"; return 0
        fi
        warn "invalid choice — enter 1-${#tags[@]} or q"
    done
}

# ui_checklist TITLE PROMPT  tag1 item1 on|off  tag2 item2 on|off ...
#   -> echoes the CHOSEN tags space-separated (may be empty), rc=1 on cancel.
# The multi-select analogue of ui_menu (whiptail --checklist / a text toggle loop).
ui_checklist() {
    local title="$1" prompt="$2"; shift 2
    if [ "${HAVE_TUI}" = 1 ]; then
        local out
        out="$(whiptail --title "${WT_TITLE} — ${title}" --notags --separate-output \
            --checklist "${prompt}" 22 78 10 "$@" 3>&1 1>&2 2>&3)" || return 1
        # --separate-output = one tag per line; join to one space-separated row.
        printf '%s' "${out}" | tr '\n' ' ' | sed -E 's/ +$//'
        return 0
    fi
    # Text fallback: [x]/[ ] rows; a number toggles, 'd'/empty = done, 'q' = cancel.
    local -a tags=() items=() states=(); local i
    while [ "$#" -ge 3 ]; do tags+=("$1"); items+=("$2"); states+=("$3"); shift 3; done
    local choice
    while true; do
        printf '\n%s== %s ==%s\n' "${C_BLD}" "${title}" "${C_RST}" >&2
        printf '%b\n' "${prompt}" >&2
        for i in "${!items[@]}"; do
            printf '  %2d) [%s] %s\n' "$((i+1))" "$([ "${states[$i]}" = on ] && echo x || echo ' ')" "${items[$i]}" >&2
        done
        printf '   d) done (keep this selection)   q) cancel\n' >&2
        read -r -p "toggle: " choice </dev/tty || return 1
        [ "${choice}" = q ] && return 1
        if [ "${choice}" = d ] || [ -z "${choice}" ]; then
            local out=""
            for i in "${!tags[@]}"; do [ "${states[$i]}" = on ] && out+="${tags[$i]} "; done
            printf '%s' "${out% }"; return 0
        fi
        if [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#tags[@]}" ]; then
            i=$((choice-1))
            states[$i]="$([ "${states[$i]}" = on ] && echo off || echo on)"
        else
            warn "invalid choice — enter 1-${#tags[@]}, d or q"
        fi
    done
}

# ui_yesno TITLE TEXT  -> rc 0 = yes, 1 = no
ui_yesno() {
    local title="$1" text="$2"
    if [ "${HAVE_TUI}" = 1 ]; then
        whiptail --title "${WT_TITLE} — ${title}" --yesno "${text}" 14 78
        return $?
    fi
    printf '\n%b\n' "${text}" >&2          # %b so embedded \n render as line breaks
    local a; read -r -p "[y/N]: " a </dev/tty || return 1
    [[ "${a}" =~ ^[Yy] ]]
}

# ui_input TITLE TEXT DEFAULT  -> echoes the entered value (default on empty/cancel)
ui_input() {
    local title="$1" text="$2" def="$3" val
    if [ "${HAVE_TUI}" = 1 ]; then
        val="$(whiptail --title "${WT_TITLE} — ${title}" --inputbox "${text}" 12 78 "${def}" 3>&1 1>&2 2>&3)" \
            || { printf '%s' "${def}"; return 0; }
        printf '%s' "${val}"; return 0
    fi
    read -r -e -i "${def}" -p "${text}: " val </dev/tty || val="${def}"
    printf '%s' "${val:-${def}}"
}

# ui_password TITLE TEXT  -> echoes the entered secret (hidden input). Never logged,
# never persisted by the caller. Empty result is a valid "skip".
ui_password() {
    local title="$1" text="$2" val
    if [ "${HAVE_TUI}" = 1 ]; then
        val="$(whiptail --title "${WT_TITLE} — ${title}" --passwordbox "${text}" 12 78 3>&1 1>&2 2>&3)" \
            || { printf ''; return 0; }
        printf '%s' "${val}"; return 0
    fi
    read -r -s -p "${text}: " val </dev/tty || val=""
    printf '\n' >&2
    printf '%s' "${val}"
}

# arm_secrets_prompt LABEL — masked, non-persisted --local-pass/--luks-pass
# entry point for the 5 platforms whose --standalone posture has no dedicated
# screen of its own (rpi5 desktop / frite / jetson desktop / orangepi5 /
# orangepizero2 — unlike x86, which has standalone_screen()). Without this,
# the only way to set these secrets on those platforms is typing them into
# the unmasked, persisted "Extra builder flags" field — see
# _arm_standalone_flags() for how these fold into STANDALONE_FLAGS instead.
arm_secrets_prompt() {
    local label="$1" choice
    while :; do
        choice="$(ui_menu "${label}: standalone secrets" "Only takes effect together with --standalone (via a role that forces it, or typed into Extra builder flags). Masked input; never saved to ${CONF_FILE}." \
            pass "Local password ..... $([ -n "${ARM_LOCAL_PASS}" ] && echo '(set)' || echo '(unset -> random at first boot)')" \
            luks "Unattended LUKS pass $([ -n "${ARM_LUKS_PASS}" ] && echo '(set — advanced)' || echo '(prompts at build/install — recommended)')" \
            done "‹ done")" || return 0
        case "${choice}" in
            pass) ARM_LOCAL_PASS="$(ui_password "Password" "Local login password (blank = random one-time at first boot)")" ;;
            luks) ARM_LUKS_PASS="$(ui_password "Unattended LUKS" "Bake an unattended LUKS passphrase (ADVANCED; blank = prompt at build/install)")" ;;
            *) return 0 ;;
        esac
    done
}

# ui_msg TITLE TEXT  -> informational box / printout
ui_msg() {
    local title="$1" text="$2"
    if [ "${HAVE_TUI}" = 1 ]; then
        whiptail --title "${WT_TITLE} — ${title}" --scrolltext --msgbox "${text}" 22 78
    else
        printf '\n%s== %s ==%s\n' "${C_BLD}" "${title}" "${C_RST}" >&2
        printf '%b\n' "${text}" >&2          # %b so embedded \n render as line breaks
        read -r -p "press Enter…" _ </dev/tty || true
    fi
}

# ── Detached-build state helpers ────────────────────────────────────────────────
# A build is OURS-and-running when the recorded PID is still alive AND still looks
# like our build (PID-reuse guard: after the build ends the OS can hand that number
# to an unrelated process; a bare `kill -0` would then report a phantom build and,
# worse, make Stop target a stranger).
menu_build_pid()  { [ -f "${PID_FILE}" ] && cat "${PID_FILE}" 2>/dev/null || true; }
menu_build_alive() {
    local p; p="$(menu_build_pid)"
    [ -n "${p}" ] || return 1
    kill -0 "${p}" 2>/dev/null || { rm -f "${PID_FILE}"; return 1; }
    local cmd=""
    [ -r "/proc/${p}/cmdline" ] && cmd="$(tr '\0' ' ' < "/proc/${p}/cmdline" 2>/dev/null)"
    case "${cmd}" in
        *make*|*docker*|*setsid*|*build-all-roles*|*stage4*) return 0 ;;
        "") return 0 ;;   # cmdline unreadable (root-owned build) but alive — trust it
        *)  rm -f "${PID_FILE}"; return 1 ;;   # reused PID — drop the stale record
    esac
}

# Detect ANY image build on this host — including one launched by hand outside this
# menu — so "bring it up with current progress" works regardless of who started it.
# Native: the host-side build scripts are visible. Docker: the build runs in the
# container's PID namespace (invisible to host pgrep), so fall back to the host-side
# `docker run <builder image>` wrapper (still a real, monitorable PID). Echoes a
# PID, or nothing.
foreign_build_pid() {
    local p
    p="$(pgrep -f 'build-all-roles\.sh|build-(rpi5|x86-host|frite|jetson|orangepi5|orangepi-zero2)-stage4\.sh' 2>/dev/null | head -n1)"
    [ -z "${p}" ] && p="$(pgrep -f "docker run.*${BUILDER_IMAGE}" 2>/dev/null | head -n1)"
    printf '%s' "${p}"
}

# True if the recorded PID is alive OR any orchestrator/stage4 build is still
# running — used to VERIFY a stop actually worked (kill's rc lies on partial kills).
_pid_or_build_alive() {
    local p="$1"
    { [ -n "${p}" ] && kill -0 "${p}" 2>/dev/null; } && return 0
    [ -n "$(foreign_build_pid)" ]
}

# Pick the most relevant live log to monitor. Prefer the log of a build we
# launched; else fall back to the builders' own combined log, or a hand-launched
# run's redirect (the WORK_DIR/build.log the stage4 scripts tee into, or the
# common ~/snap-build.log redirect). Newest wins.
active_log() {
    local m=""; [ -f "${META_FILE}" ] && m="$(grep -m1 '^log=' "${META_FILE}" 2>/dev/null | cut -d= -f2-)"
    local -a cands=()
    [ -n "${m}" ] && cands+=("${m}")
    cands+=("${OPT_WORK_DIR}/build.log" "${HOME}/snap-build.log")
    local best="" f
    for f in "${cands[@]}"; do
        [ -f "${f}" ] || continue
        if [ -z "${best}" ] || [ "${f}" -nt "${best}" ]; then best="${f}"; fi
    done
    printf '%s' "${best}"
}

# _shell_quote VALUE — wrap VALUE in single quotes (escaping any embedded
# single quote as '\'') so it survives being textually re-expanded, UNQUOTED,
# into a Makefile recipe line (which GNU Make hands to a real shell) as ONE
# safe literal argument — regardless of embedded whitespace, $, backticks, or
# ;. Every secret value folded into STANDALONE_FLAGS below MUST go through
# this: without it, a password containing a shell metacharacter is executed as
# shell syntax rather than passed as a literal value (real command injection,
# not just word-splitting — see the Makefile's STANDALONE_FLAGS export comment
# for the OTHER half of this fix, the Docker-dispatch hop's own re-quoting).
_shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# _redacted_run_make ARGS... — echoes a `make`-argv array joined for safe
# display/logging: any element shaped like STANDALONE_FLAGS=...--local-pass...
# or ...--luks-pass... is replaced WHOLESALE with a fixed placeholder. Used by
# launch_build()'s console/log preview; the REAL (unredacted) RUN_MAKE array is
# always what actually gets passed to `make`. Redacts the whole element rather
# than regex-matching a value inside a flattened string: since _shell_quote()
# wraps secrets in single quotes, a multi-word secret contains spaces of its
# own — a token-based regex would only mask the first word and leave the rest
# (plus a dangling quote) printed in the clear.
_redacted_run_make() {
    local -a arr=("$@")
    local i
    for i in "${!arr[@]}"; do
        case "${arr[${i}]}" in
            STANDALONE_FLAGS=*--local-pass*|STANDALONE_FLAGS=*--luks-pass*)
                arr[${i}]="STANDALONE_FLAGS=<redacted>" ;;
        esac
    done
    printf '%s' "${arr[*]}"
}

# _arm_standalone_flags — compose STANDALONE_FLAGS for the 5 ARM single-role
# targets (rpi-%/frite/jetson-%/orangepi5/orangepizero2): folds the masked
# ARM_LOCAL_PASS/ARM_LUKS_PASS secrets in FIRST (each shell-quoted via
# _shell_quote — see there for why), then the freeform "Extra builder flags"
# field LAST so it can still override — mirrors the x86 `bf` string's own
# ordering (STANDALONE_FLAGS block above).
_arm_standalone_flags() {
    local bf=""
    [ -n "${ARM_LOCAL_PASS}" ] && bf+=" --local-pass $(_shell_quote "${ARM_LOCAL_PASS}")"
    [ -n "${ARM_LUKS_PASS}" ]  && bf+=" --luks-pass $(_shell_quote "${ARM_LUKS_PASS}")"
    [ -n "${OPT_EXTRA_FLAGS}" ] && bf+=" ${OPT_EXTRA_FLAGS}"
    printf '%s' "${bf# }"
}

# ── Compose the make command for a given selection ──────────────────────────────
# Returns (via globals) the env-var prefix + the make argument list. Everything
# the menu can tweak is mapped onto the existing Makefile knobs — no new engine.
RUN_DESC=""; RUN_ROLES_TOTAL=1; declare -a RUN_MAKE=()
build_make_cmd() {
    local target="$1" desc="$2" roles_total="$3"
    RUN_DESC="${desc}"; RUN_ROLES_TOTAL="${roles_total}"
    RUN_MAKE=("${target}")
    # standalone-unaffiliated: the role PRESETS a neutral (brand-free) identity and
    # the builder HARD-ERRORS on any brand/branding/seed-code flag — so this menu
    # must never emit them for that one target (not even the BRAND= profile
    # make-var, which expands to a `--config brands/<name>.conf` brand profile).
    local unaff=no
    [ "${target}" = x86-standalone-unaffiliated ] && unaff=yes
    # Make-vars are passed as args (they override ?= defaults cleanly).
    RUN_MAKE+=("WORK_DIR=${OPT_WORK_DIR}" "JOBS=${OPT_JOBS}" "ENV=${OPT_ENV}")
    [ -n "${OPT_BRAND}" ] && [ "${unaff}" = no ] && RUN_MAKE+=("BRAND=${OPT_BRAND}")
    [ -n "${OPT_DOMAIN}" ] && RUN_MAKE+=("DOMAIN=${OPT_DOMAIN}")
    # IMG_FLAGS is expanded VERBATIM into the rpi/x86/frite/jetson/orangepi5/
    # orangepizero2 builder invocations (every $(RPI)/$(X86)/$(FRITE_BUILD)/
    # $(JETSON_BUILD)/$(ORANGEPI5_BUILD)/$(ORANGEPIZERO2_BUILD) macro embeds
    # $(IMG_FLAGS)), so it doubles as the extra-builder-flags channel for the
    # targets that do NOT consume STANDALONE_FLAGS (rpi / x86 / omnibus fleet
    # targets — a heterogeneous multi-role build has no single role to apply a
    # standalone-shaped flag to). rpi-%/x86-*/jetson-*/frite/orangepi5/
    # orangepizero2 (single-role) get the extra flags via STANDALONE_FLAGS
    # below instead — never both, which would pass them twice (the builder
    # macros already contain $(IMG_FLAGS)).
    local imgflags="${OPT_IMGFLAGS}"
    case "${target}" in
        x86-*|jetson-*|frite|orangepi5|orangepizero2|rpi-*|build-all|build-everything) ;;   # STANDALONE_FLAGS channel / no passthrough
        *) [ -n "${OPT_EXTRA_FLAGS}" ] && imgflags="${imgflags:+${imgflags} }${OPT_EXTRA_FLAGS}" ;;
    esac
    [ -n "${imgflags}" ] && RUN_MAKE+=("IMG_FLAGS=${imgflags}")
    # Root SSH login: only forwarded when opted IN; empty => every image stays hardened
    # (PermitRootLogin no) by the builders' own default. Applies to ALL targets/arches.
    [ -n "${OPT_ROOT_LOGIN}" ] && [ "${OPT_ROOT_LOGIN}" != "no" ] && RUN_MAKE+=("PERMIT_ROOT_LOGIN=${OPT_ROOT_LOGIN}")
    [ "${OPT_PATH}" = native ] && RUN_MAKE+=("NATIVE=1")
    # RESUME, X86_OMNIBUS, FRITE_FLEET/JETSON_FLEET and PENTEST are read ONLY by
    # scripts/build-all-roles.sh, which the Makefile invokes from BOTH full-fleet
    # targets — build-all (default fleet) and build-everything (build-all plus
    # X86_ROLES/FRITE/JETSON overrides; still ends up at build-all-roles.sh). The
    # per-arch / single-role targets ignore them — and a single-role build
    # WITHOUT --resume deliberately WIPES its sysroot. So emitting them for those
    # targets is at best a silent no-op and at worst a destructive surprise. Gate
    # them to the two fleet targets (the Options screen tells the user they apply
    # there).
    if [ "${target}" = build-all ] || [ "${target}" = build-everything ]; then
        [ "${OPT_RESUME}" = yes ]      && RUN_MAKE+=("RESUME=--resume")
        [ "${OPT_OMNIBUS}" = yes ]     && RUN_MAKE+=("X86_OMNIBUS=1")
        [ "${OPT_FRITE_FLEET}" = yes ]  && RUN_MAKE+=("FRITE=1")
        [ "${OPT_JETSON_FLEET}" = yes ] && RUN_MAKE+=("JETSON=1")
        [ "${OPT_ORANGEPI5_FLEET}" = yes ] && RUN_MAKE+=("ORANGEPI5=1")
        [ "${OPT_PENTEST}" = yes ]     && RUN_MAKE+=("PENTEST=1")
    fi
    # ── RPi (bare 'rpi' 3-role fleet target AND rpi-% single-role targets): the
    # board axis. OPT_RPI_BOARD maps onto the builder's --board rpi5|rpi4|rpi3
    # via the Makefile's RPI_BOARD var (baked into the $(RPI) command that BOTH the
    # 'rpi' and 'rpi-%' targets use), same pattern as FRITE_BOARD/JETSON_BOARD
    # below — threaded to BOTH so a board picked in the single-role screen does
    # not silently revert to rpi5 if the operator instead launches the 3-role
    # fleet build from the main menu.
    if [ "${target}" = rpi ] || [[ "${target}" == rpi-* ]]; then
        RUN_MAKE+=("RPI_BOARD=${OPT_RPI_BOARD}")
    fi
    # rpi-% (single-role) ALSO gets the escape hatch, incl. --standalone/
    # --local-user/--local-pass (only meaningful on rpi-desktop — the builder
    # hard-errors on --standalone for the cluster-node roles). The bare 'rpi'
    # fleet target does NOT (it has no single role to apply a standalone-shaped
    # flag to — same reasoning as x86's plain fleet target).
    if [[ "${target}" == rpi-* ]]; then
        { local _armflags; _armflags="$(_arm_standalone_flags)"; [ -n "${_armflags}" ] && RUN_MAKE+=("STANDALONE_FLAGS=${_armflags}"); }
    fi
    # Frite board/flavor/desktop only matter for the frite target but are harmless
    # else. FRITE_BOARD/FRITE_FLAVOR/FRITE_DESKTOP map onto the builder's --board /
    # --flavor / --desktop light|none knobs, which the Makefile frite target
    # threads. Extra builder flags (--enable-wifi / --uboot-url / --img-size …)
    # ride STANDALONE_FLAGS, appended verbatim by the frite recipe — same escape
    # hatch as x86-*/jetson-*.
    if [ "${target}" = frite ]; then
        RUN_MAKE+=("FRITE_BOARD=${OPT_FRITE_BOARD}" "FRITE_FLAVOR=${OPT_FRITE_FLAVOR}" "FRITE_DESKTOP=${OPT_FRITE_DESKTOP}")
        { local _armflags; _armflags="$(_arm_standalone_flags)"; [ -n "${_armflags}" ] && RUN_MAKE+=("STANDALONE_FLAGS=${_armflags}"); }
    fi
    # ── Jetson (jetson-% targets): its OWN axes as make-vars + the escape hatch ──
    # JETSON_BOARD / JETSON_KERNEL_FLAVOR map onto the builder's --board /
    # --kernel-flavor; extra builder flags thread via STANDALONE_FLAGS, which the
    # Makefile jetson/jetson-% targets append verbatim after --kernel-flavor. The
    # x86 knobs composed below (--optional-services / --with-tor / the edge-AI
    # model-library / branding overrides / --installer-ui) are deliberately NOT
    # emitted here: build-jetson-stage4.sh does not take them yet (its edge_ai/full
    # roles always bake the edge-ai service; gate_optional_services is not
    # replicated there — specs-jetson/README.md) and an unknown flag hard-fails the
    # builder. Any flag the Jetson builder DOES grow is reachable immediately via
    # the extra-flags hatch (the all-options-in-all-menus rule).
    if [[ "${target}" == jetson-* ]]; then
        RUN_MAKE+=("JETSON_BOARD=${OPT_JETSON_BOARD}" "JETSON_KERNEL_FLAVOR=${OPT_JETSON_KFLAVOR}")
        { local _armflags; _armflags="$(_arm_standalone_flags)"; [ -n "${_armflags}" ] && RUN_MAKE+=("STANDALONE_FLAGS=${_armflags}"); }
    fi
    # ── Orange Pi 5 (EXPERIMENTAL): its OWN axes as make-vars + the escape hatch ──
    # ORANGEPI5_BOARD / ORANGEPI5_FLAVOR map onto the builder's --board /
    # --flavor; extra builder flags (incl. --standalone/--encrypt-root) thread
    # via STANDALONE_FLAGS, which the Makefile orangepi5 target appends
    # verbatim after --flavor — same escape hatch as frite/jetson-*/x86-*. The
    # x86-only cluster-service/edge-AI/branding/installer-UI knobs are
    # deliberately NOT emitted here (this platform's builder does not take
    # them; an unknown flag hard-fails it) — mirrors the jetson-* block above.
    if [ "${target}" = orangepi5 ]; then
        RUN_MAKE+=("ORANGEPI5_BOARD=${OPT_ORANGEPI5_BOARD}" "ORANGEPI5_FLAVOR=${OPT_ORANGEPI5_FLAVOR}")
        { local _armflags; _armflags="$(_arm_standalone_flags)"; [ -n "${_armflags}" ] && RUN_MAKE+=("STANDALONE_FLAGS=${_armflags}"); }
    fi
    # ── Orange Pi Zero 2 (EXPERIMENTAL): its OWN axis (flavor only — no board,
    # no --desktop, see specs-orangepi-zero2/README.md) as a make-var + the
    # escape hatch. ORANGEPIZERO2_FLAVOR maps onto the builder's --flavor;
    # extra builder flags (incl. --standalone/--encrypt-root) thread via
    # STANDALONE_FLAGS, which the Makefile orangepizero2 target appends
    # verbatim after --flavor — same escape hatch as frite/jetson-*/orangepi5/
    # x86-*. The x86-only cluster-service/edge-AI/branding/installer-UI knobs
    # are deliberately NOT emitted here (this platform's builder does not take
    # them; an unknown flag hard-fails it) — mirrors the orangepi5 block above.
    if [ "${target}" = orangepizero2 ]; then
        RUN_MAKE+=("ORANGEPIZERO2_FLAVOR=${OPT_ORANGEPIZERO2_FLAVOR}")
        { local _armflags; _armflags="$(_arm_standalone_flags)"; [ -n "${_armflags}" ] && RUN_MAKE+=("STANDALONE_FLAGS=${_armflags}"); }
    fi
    # ── Builder flags threaded via STANDALONE_FLAGS (x86-* targets) ─────────────
    # The Makefile x86-% / x86-standalone* targets append STANDALONE_FLAGS verbatim
    # after --role, so EVERY x86 builder flag is reachable from this menu (the
    # all-options-in-all-menus rule). ALL blocks below fold into ONE bf string — a
    # single make invocation never gets a double STANDALONE_FLAGS= emit.
    case "${target}" in x86-*)
        local bf=""
        # Standalone hardened NVIDIA desktop: the collected desktop options.
        # NOTE: --local-pass lands in the process argv (visible to `ps` on this box);
        # acceptable on a single-user build host. The builder hashes it immediately and
        # never bakes the plaintext. The LUKS root passphrase is NOT passed here unless
        # the user opts into an unattended one — the installer prompts at install time.
        if [[ "${target}" == x86-standalone* ]]; then
            bf+=" --gpu-driver ${OPT_SA_GPU}"
            bf+=" --steam ${OPT_SA_STEAM}"
            [ "${OPT_SA_MEDIA}" = no ] && bf+=" --no-media-data"
            # match the media data device by FS LABEL (only meaningful with media ON)
            [ "${OPT_SA_MEDIA}" = yes ] && [ -n "${OPT_SA_MEDIA_LABEL}" ] && bf+=" --media-label ${OPT_SA_MEDIA_LABEL}"
            [ -n "${OPT_SA_USER}" ] && bf+=" --local-user $(_shell_quote "${OPT_SA_USER}")"
            [ -n "${SA_LOCAL_PASS}" ] && bf+=" --local-pass $(_shell_quote "${SA_LOCAL_PASS}")"
            [ -n "${SA_LUKS_PASS}" ]  && bf+=" --luks-pass $(_shell_quote "${SA_LUKS_PASS}")"
            [ "${OPT_SA_KEYFILE}" != none ] && bf+=" --unlock-keyfile ${OPT_SA_KEYFILE}"
            [ "${OPT_SA_YUBIKEY}" != none ] && bf+=" --unlock-yubikey ${OPT_SA_YUBIKEY}"
            # branding theme + security stack + monolithic kernel + egress VPN.
            # unaffiliated: NEVER --theme (a hard conflict), even though
            # OPT_SA_THEME's persisted default is 'boogiepop'.
            { [ "${unaff}" = no ] && [ -n "${OPT_SA_THEME}" ] && [ "${OPT_SA_THEME}" != none ]; } && bf+=" --theme ${OPT_SA_THEME}"
            [ "${OPT_SA_PROXY}" = no ]    && bf+=" --no-proxy-stack"
            [ "${OPT_SA_SNORT}" = no ]    && bf+=" --no-snort"
            [ "${OPT_SA_AIDE}" = yes ]    && bf+=" --with-aide"
            [ "${OPT_SA_KBUILTIN}" = yes ] && bf+=" --kernel-builtin"
            [ -n "${OPT_SA_EGRESS}" ]     && bf+=" --egress-vpn ${OPT_SA_EGRESS}"
        else
            # OPTIONAL services catalog + Tor + Character Studio — CLUSTER-role knobs
            # (standalone desktops are not cluster members, so they are skipped there;
            # on the tailnet CLIENT desktops the builder's !ROLE_CLIENT guard makes an
            # accidental --with-*/--optional-services a loud, harmless no-op).
            if [ "${OPT_SERVICES}" = none ]; then
                bf+=' --optional-services ""'
            elif [ -n "${OPT_SERVICES}" ]; then
                # comma list -> the builder's space-separated list (kept as ONE shell
                # word via embedded double quotes, which survive both make legs).
                bf+=" --optional-services \"${OPT_SERVICES//,/ }\""
                # games is opt-in — mirror the checklist with the explicit toggle too
                case ",${OPT_SERVICES}," in *,games,*) bf+=" --enable-games" ;; esac
            fi
            [ "${OPT_TOR_ONION}" = yes ] && bf+=" --with-tor"
            [ "${OPT_CHARACTER_STUDIO}" = yes ] && bf+=" --with-character-studio"
            # edge-ai-tts rides HERE (not the GPU-target case below with
            # edge-ai-analysis) — it is CPU-only + self-contained, NO edge-ai
            # dependency, so it applies to any cluster role, GPU or not.
            [ "${OPT_EDGE_AI_TTS}" = yes ] && bf+=" --with-edge-ai-tts"
        fi
        # Edge-AI inference service on a GPU cluster role. The x86 edge_ai role
        # ALWAYS bakes it (auto-selected by the builder); the other GPU-capable
        # roles add it only when OPT_X86_EDGE_AI=yes. (The Jetson edge_ai/full
        # roles bake it builder-side too, but the --with-edge-ai/--edge-ai-* knobs
        # are x86-only flags — see the jetson-* block above.)
        case "${target}" in
            x86-be+gpu|x86-omnibus|x86-edge_ai)
                local ai_always=no
                case "${target}" in x86-edge_ai) ai_always=yes ;; esac
                [ "${ai_always}" = no ] && [ "${OPT_X86_EDGE_AI}" = yes ] && bf+=" --with-edge-ai"
                if [ "${ai_always}" = yes ] || [ "${OPT_X86_EDGE_AI}" = yes ]; then
                    [ -n "${OPT_EDGE_AI_RUNTIME}" ] && [ "${OPT_EDGE_AI_RUNTIME}" != ollama ] && bf+=" --edge-ai-runtime ${OPT_EDGE_AI_RUNTIME}"
                    [ -n "${OPT_EDGE_AI_MODELS}" ]  && bf+=" --edge-ai-models ${OPT_EDGE_AI_MODELS}"
                    [ -n "${OPT_EDGE_AI_MODEL_DEFAULT}" ] && bf+=" --edge-ai-model-default ${OPT_EDGE_AI_MODEL_DEFAULT}"
                fi
                # --with-edge-ai-analysis folds edge-ai too (its dependency), so it applies
                # on any GPU target incl. the edge_ai role.
                [ "${OPT_X86_EDGE_AI_ANALYSIS}" = yes ] && bf+=" --with-edge-ai-analysis"
                ;;
        esac
        # Advanced branding OVERRIDES — single artwork/palette pieces layered on top
        # of the brand profile / theme preset. Apply to ANY x86 image (x86-only
        # flags: the Jetson builder has no branding-override surface yet) EXCEPT
        # the unaffiliated desktop, where every branding flag is a hard conflict.
        if [ "${unaff}" = no ]; then
            [ -n "${OPT_BR_WALLPAPER}" ] && bf+=" --wallpaper ${OPT_BR_WALLPAPER}"
            [ -n "${OPT_BR_GRUB_BG}" ]   && bf+=" --grub-background ${OPT_BR_GRUB_BG}"
            [ -n "${OPT_BR_LOGIN_BG}" ]  && bf+=" --login-background ${OPT_BR_LOGIN_BG}"
            [ -n "${OPT_BR_LOGO}" ]      && bf+=" --brand-logo ${OPT_BR_LOGO}"
            [ -n "${OPT_BR_ACCENT}" ]    && bf+=" --accent-color ${OPT_BR_ACCENT}"
            [ -n "${OPT_BR_SCHEME}" ]    && bf+=" --color-scheme ${OPT_BR_SCHEME}"
        fi
        # Home provisioning — standalone + tailnet CLIENT desktops only (a cluster
        # node has no provisioned user home to adopt/restore).
        case "${target}" in
            x86-standalone*|x86-laptop|x86-chromebook|x86-desktop)
                [ -n "${OPT_HOME_MODE}" ]    && bf+=" --home-mode ${OPT_HOME_MODE}"
                [ -n "${OPT_HOME_DEVICE}" ]  && bf+=" --home-device ${OPT_HOME_DEVICE}"
                [ -n "${OPT_HOME_BACKUP}" ]  && bf+=" --home-backup ${OPT_HOME_BACKUP}"
                [ "${OPT_HOME_ENCRYPTED}" = yes ] && bf+=" --home-encrypted"
                # unaffiliated: --home-seed-code seeds the Snapdragon stack — hard conflict
                { [ "${unaff}" = no ] && [ -n "${OPT_HOME_SEED}" ] && [ "${OPT_HOME_SEED}" != none ]; } && bf+=" --home-seed-code ${OPT_HOME_SEED}"
                [ -n "${OPT_HOME_ARCHIVE}" ] && bf+=" --include-home-archive ${OPT_HOME_ARCHIVE}"
                ;;
        esac
        # Installer front-ends offered on the live ISO (empty = builder default:
        # standalone='all', everything else 'cli').
        [ -n "${OPT_INSTALLER_UI}" ] && bf+=" --installer-ui ${OPT_INSTALLER_UI}"
        # Extra builder flags — the verbatim escape hatch, LAST so they can override.
        [ -n "${OPT_EXTRA_FLAGS}" ] && bf+=" ${OPT_EXTRA_FLAGS}"
        [ -n "${bf}" ] && RUN_MAKE+=("STANDALONE_FLAGS=${bf# }")
        ;;
    esac
}

# Launch the composed build DETACHED and record its PID + metadata, so we can
# quit freely and re-attach later. setsid => new session (survives this menu and
# the terminal); </dev/null => no stdin; output captured to our own run log.
launch_build() {
    local runlog="${STATE_DIR}/run-$(date +%Y%m%d-%H%M%S).log"
    local -a launch=()
    # A NATIVE build runs as root. We must NOT let an inner, no-tty `sudo` (under
    # setsid) try to re-authenticate — with sudo's default tty-scoped credential
    # timestamp it cannot, and the detached build would die instantly. Instead:
    # authenticate ONCE here (tty present), then run the WHOLE detached pipeline
    # under that single `sudo` (before setsid drops the tty). The inner make then
    # sees uid 0 and adds no nested sudo. Pass the real uid/gid so it chowns the
    # finished artifacts back to you.
    if [ "${OPT_PATH}" = native ] && [ "$(id -u)" != 0 ]; then
        say "native build needs root — caching your sudo credential…"
        sudo -v </dev/tty || { ui_msg "Build" "sudo authentication failed — build not started."; return 1; }
        launch=(sudo)
        RUN_MAKE+=("HOST_UID=$(id -u)" "HOST_GID=$(id -g)")
    fi
    # Log the command with any --local-pass/--luks-pass values REDACTED (the real
    # values are still passed to make below — only the echoed/saved copy is masked).
    say "launching: ${launch[*]:-} make $(_redacted_run_make "${RUN_MAKE[@]}")"
    (
        cd "${REPO_DIR}" || exit 1
        exec "${launch[@]}" setsid nohup make "${RUN_MAKE[@]}" \
            > "${runlog}" 2>&1 < /dev/null
    ) &
    local pid=$!
    printf '%s\n' "${pid}" > "${PID_FILE}"
    {
        printf 'pid=%s\n'     "${pid}"
        printf 'log=%s\n'     "${runlog}"
        printf 'desc=%s\n'    "${RUN_DESC}"
        printf 'target=%s\n'  "${RUN_MAKE[0]}"
        printf 'roles=%s\n'   "${RUN_ROLES_TOTAL}"
        printf 'path=%s\n'    "${OPT_PATH}"
        printf 'started=%s\n' "$(date +%s)"
    } > "${META_FILE}"
    ui_msg "Build started" \
"Started: ${RUN_DESC}
PID:     ${pid}  (detached — quitting the menu will NOT stop it)
Log:     ${runlog}

Opening the live monitor next. Press 'q' in the monitor to return here;
the build keeps running in the background."
    monitor_build
}

# Best-effort stop of a running build. A NATIVE build runs as root (sudo), so
# stopping it needs root too — we try sudo and report honestly if we cannot.
stop_build() {
    local pid; pid="$(menu_build_pid)"; [ -z "${pid}" ] && pid="$(foreign_build_pid)"
    [ -z "${pid}" ] && { ui_msg "Stop" "No running build found."; return 0; }
    ui_yesno "Stop build" "Kill the running build (PID ${pid}) and its children?\n\nThis ABORTS the build. Use 'q' instead to just leave the monitor." || return 0
    # A native build's real work runs as ROOT (sudo emerge/stage4) in the same
    # process group as the user-owned `make` leader. kill(2) returns 0 if it
    # signalled ANY group member, so a user `kill` can "succeed" while the root
    # build lives on. So we do NOT trust kill's return code: signal, then VERIFY,
    # escalating to sudo, and only report success once nothing is left alive.
    kill -- -"${pid}" 2>/dev/null || kill "${pid}" 2>/dev/null || true
    sleep 1
    if _pid_or_build_alive "${pid}"; then
        say "build survived SIGTERM — escalating via sudo…"
        sudo kill -- -"${pid}" 2>/dev/null || sudo kill "${pid}" 2>/dev/null || true
        sleep 1
    fi
    if _pid_or_build_alive "${pid}"; then
        ui_msg "Stop" "Could NOT stop build ${pid} (insufficient privilege?).\nIt is STILL running — its PID is kept so you can keep monitoring it."
    else
        rm -f "${PID_FILE}"
        ui_msg "Stop" "Build ${pid} stopped."
    fi
}

# ── Progress parsing + the live monitor screen ──────────────────────────────────
# A textual progress bar: bar PCT [WIDTH]
bar() {
    local pct="${1:-0}" width="${2:-46}" i filled
    [ "${pct}" -gt 100 ] 2>/dev/null && pct=100
    [ "${pct}" -lt 0 ]   2>/dev/null && pct=0
    filled=$(( pct * width / 100 ))
    printf '['
    for ((i=0; i<width; i++)); do (( i < filled )) && printf '#' || printf ' '; done
    printf '] %3d%%' "${pct}"
}

# Echoes:  PKG_CUR PKG_TOTAL PKG_PCT ROLE_LABEL PKG_NAME
# from the tail of a build log (emerge "(X of Y)" counter + role banner).
parse_progress() {
    local log="$1" tail_lines
    tail_lines="$(tail -n 4000 "${log}" 2>/dev/null)"
    local cur=0 total=0 pct=0 role="(starting)" pkg="—" line
    # Latest emerge/installing package counter, e.g. ">>> Emerging (12 of 345) cat/pkg-1.2".
    line="$(printf '%s\n' "${tail_lines}" | grep -aE '>>> (Emerging|Installing) \([0-9]+ of [0-9]+\)' | tail -n1)"
    if [ -n "${line}" ]; then
        cur="$(  printf '%s' "${line}" | sed -E 's/.*\(([0-9]+) of ([0-9]+)\).*/\1/')"
        total="$(printf '%s' "${line}" | sed -E 's/.*\(([0-9]+) of ([0-9]+)\).*/\2/')"
        pkg="$(   printf '%s' "${line}" | sed -E 's/.*\([0-9]+ of [0-9]+\) +([^ ]+).*/\1/')"
        [ "${total}" -gt 0 ] 2>/dev/null && pct=$(( cur * 100 / total ))
    fi
    # Latest per-role banner. Grep the WHOLE log, not just the tail: on a long
    # single-role build the "Building … role:" banner is printed once at the start
    # and scrolls far out of the recent-tail window.
    local rline
    rline="$(grep -aE '(#  Building (RPi5|x86|Frite|Jetson)|^==> (Pi|x86|Frite|Jetson) |Building .* role:)' "${log}" 2>/dev/null | tail -n1)"
    [ -n "${rline}" ] && role="$(printf '%s' "${rline}" | sed -E 's/^[[:space:]#=>]*//; s/\x1b\[[0-9;]*m//g' | cut -c1-46)"
    printf '%s %s %s %s %s' "${cur}" "${total}" "${pct}" "${role}" "${pkg}"
}

# Render one frame of the monitor.
draw_monitor() {
    local log="$1"
    local elapsed_s=0 started desc target roles_total have_total=0
    [ -f "${META_FILE}" ] && {
        started="$(grep -m1 '^started=' "${META_FILE}" | cut -d= -f2-)"
        desc="$(grep -m1 '^desc=' "${META_FILE}" | cut -d= -f2-)"
        target="$(grep -m1 '^target=' "${META_FILE}" | cut -d= -f2-)"
        roles_total="$(grep -m1 '^roles=' "${META_FILE}" | cut -d= -f2-)"
        [ -n "${roles_total:-}" ] && have_total=1
        [ -n "${started:-}" ] && elapsed_s=$(( $(date +%s) - started ))
    }
    [ -z "${desc:-}" ] && desc="image build (external — started outside this menu)"
    [ -z "${roles_total:-}" ] && roles_total=1
    # parse_progress returns "PKG_CUR PKG_TOTAL PKG_PCT ROLE… PKG_NAME"; the role
    # label can contain spaces, so word-split and peel the numeric head off. Disable
    # globbing first so a stray '*'/'?' in a log-derived label can't expand to repo
    # filenames.
    set -f; set -- $(parse_progress "${log}"); set +f
    local pc="${1:-0}" pt="${2:-0}" pp="${3:-0}"; shift 3 2>/dev/null || true
    local prole="${*:-}"
    # Recompute role label + pkg cleanly (the role label may contain spaces).
    local pkgname; pkgname="$(printf '%s' "${prole}" | awk '{print $NF}')"
    local rolelabel; rolelabel="$(printf '%s' "${prole}" | sed -E 's/[^ ]+$//; s/[[:space:]]+$//')"
    [ -z "${rolelabel}" ] && rolelabel="(building)"

    # Roles-done proxy: count distinct per-role start banners seen so far.
    # grep -c always PRINTS a count but returns rc=1 when it is zero; a `|| echo 0`
    # would then append a second "0" line, and "$(( 0\n0 - 1 ))" is a fatal
    # arithmetic SYNTAX error. So take grep's output as-is and sanitize to one int.
    local roles_seen
    roles_seen="$(grep -acE '(#  Building (RPi5|x86|Frite|Jetson)|^==> (Pi|x86|Frite|Jetson) )' "${log}" 2>/dev/null)"
    roles_seen="${roles_seen//[^0-9]/}"; roles_seen="${roles_seen:-0}"
    [ "${roles_seen}" -lt 1 ] && roles_seen=1
    local overall_pct=0 overall_label
    if [ "${have_total}" = 1 ] && [ "${roles_total}" -gt 0 ] 2>/dev/null; then
        # Planned total is known (menu-launched): completed roles = seen-1 (current
        # in progress); add the current role's package fraction.
        overall_pct=$(( ( (roles_seen - 1) * 100 + pp ) / roles_total ))
        [ "${overall_pct}" -gt 100 ] && overall_pct=100
        [ "${overall_pct}" -lt 0 ]   && overall_pct=0
        overall_label="(role ${roles_seen} of ${roles_total})"
    else
        # External build: planned total unknown — track the current role's packages
        # and just report how many roles we have SEEN start.
        overall_pct="${pp}"
        overall_label="(role ${roles_seen} in progress — total unknown)"
    fi

    local hh mm ss; hh=$(( elapsed_s/3600 )); mm=$(( (elapsed_s%3600)/60 )); ss=$(( elapsed_s%60 ))
    # Clear-screen only on an interactive stdout (so captured/redirected output
    # isn't littered with control bytes); UTF-8 box-art only in a UTF-8 locale
    # (the C/POSIX Docker builder image would render it as mojibake).
    [ -t 1 ] && printf '\033[2J\033[H' || printf '\n'
    if [ "${UTF8}" = 1 ]; then
        printf '%s%s  ╔══════════════════════════════════════════════════════════════════╗%s\n' "${C_BLD}" "${C_CYN}" "${C_RST}"
        printf '%s%s  ║  Snapdragon Image Build — live monitor                            ║%s\n' "${C_BLD}" "${C_CYN}" "${C_RST}"
        printf '%s%s  ╚══════════════════════════════════════════════════════════════════╝%s\n\n' "${C_BLD}" "${C_CYN}" "${C_RST}"
    else
        printf '%s%s  == Snapdragon Image Build - live monitor ==%s\n\n' "${C_BLD}" "${C_CYN}" "${C_RST}"
    fi
    printf '  %sBuilding:%s %s\n'   "${C_BLD}" "${C_RST}" "${desc}"
    printf '  %sPath:%s %s   %sElapsed:%s %02d:%02d:%02d   %sLog:%s %s\n\n' \
        "${C_BLD}" "${C_RST}" "${OPT_PATH}" "${C_BLD}" "${C_RST}" "${hh}" "${mm}" "${ss}" \
        "${C_BLD}" "${C_RST}" "${C_DIM}$(basename "${log}")${C_RST}"
    printf '  %sOverall%s  %s   %s\n' "${C_BLD}" "${C_RST}" "${overall_label}" "$(bar "${overall_pct}")"
    printf '  %sRole%s     %s\n' "${C_BLD}" "${C_RST}" "${rolelabel}"
    printf '  %sPackage%s  %s of %s   %s\n' "${C_BLD}" "${C_RST}" "${pc}" "${pt}" "$(bar "${pp}")"
    printf '           %s%s%s\n\n' "${C_DIM}" "${pkgname:-—}" "${C_RST}"
    printf '  %s── recent log ──────────────────────────────────────────────────────%s\n' "${C_DIM}" "${C_RST}"
    tail -n 10 "${log}" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g; s/^/  | /' | cut -c1-78
    printf '\n  %s[q]%s back to menu (build keeps running)   %s[s]%s stop build   %s[r]%s refresh\n' \
        "${C_BLD}" "${C_RST}" "${C_BLD}" "${C_RST}" "${C_BLD}" "${C_RST}"
}

# The monitor loop: redraw every 2s, return on 'q', stop on 's'. A `read` timeout
# returns >128 — harmless, we just loop and redraw.
monitor_build() {
    local log; log="$(active_log)"
    if [ -z "${log}" ] || [ ! -f "${log}" ]; then
        ui_msg "Monitor" "No build log found yet at:\n  ${OPT_WORK_DIR}/build.log\n\nIf you just started a build, give it a few seconds and try again."
        return 0
    fi
    # The interactive key loop needs a READABLE controlling terminal. Without one
    # (cron/CI/piped/redirected), `read … </dev/tty` returns instantly instead of
    # honouring -t, which would spin the loop at 100% CPU and spam errors. In that
    # case just print one snapshot and return.
    if [ ! -t 1 ] || ! { : < /dev/tty; } 2>/dev/null; then
        draw_monitor "${log}"
        return 0
    fi
    local key rc
    while true; do
        draw_monitor "${log}"
        if ! menu_build_alive && [ -z "$(foreign_build_pid)" ]; then
            printf '\n  %sBuild process has exited.%s Showing final state — press Enter to return.\n' "${C_YEL}" "${C_RST}"
            read -r _ </dev/tty || true
            rm -f "${PID_FILE}"
            return 0
        fi
        if read -rsn1 -t 2 key </dev/tty; then
            case "${key}" in
                q|Q) return 0 ;;
                s|S) stop_build; return 0 ;;
                *)   : ;;  # any other key = immediate refresh
            esac
        else
            # read failed: a -t timeout returns >128 (expected, just loop again); a
            # smaller rc means the tty vanished mid-run — sleep so we never busy-spin.
            rc=$?; [ "${rc}" -le 128 ] && sleep 2
        fi
    done
}

# ── Menu screens ────────────────────────────────────────────────────────────────
# Edge-AI inference service options (GPU cluster roles). The edge_ai ROLE always
# bakes the service; this screen toggles adding it to be+gpu/omnibus and tunes the
# model library (runtime + preload list + default model) — the same knobs the
# Studio wizard + the --edge-ai-* CLI flags expose (all-menus parity). The Voice
# synthesis (TTS) row rides here for UX grouping only — unlike Analysis API it has
# NO edge-ai dependency (CPU-only, self-contained) and its flag is emitted
# unconditionally below (not gated to the GPU-target case).
edge_ai_options_screen() {
    while true; do
        local on; on="$([ "${OPT_X86_EDGE_AI}" = yes ] && echo on || echo off)"
        local c
        c="$(ui_menu "Edge-AI inference" "GPU inference service — OpenAI model API to the mesh:" \
            toggle  "Add to be+gpu/omnibus . ${on}   (the edge_ai role always has it)" \
            runtime "Runtime ............... ${OPT_EDGE_AI_RUNTIME}   (ollama | vllm)" \
            models  "Preload models ........ ${OPT_EDGE_AI_MODELS:-<builder default>}" \
            default "Default model ......... ${OPT_EDGE_AI_MODEL_DEFAULT:-<builder default>}" \
            analysis "Analysis API .......... $([ "${OPT_X86_EDGE_AI_ANALYSIS}" = yes ] && echo on || echo off)   (image/log verdicts; separate image)" \
            tts     "Voice synthesis (TTS) . $([ "${OPT_EDGE_AI_TTS}" = yes ] && echo on || echo off)   (Piper TTS + visemes; CPU-only, no edge-ai needed; separate image)" \
            back    "‹ back")" || return 0
        case "${c}" in
            toggle)  OPT_X86_EDGE_AI="$([ "${OPT_X86_EDGE_AI}" = yes ] && echo no || echo yes)" ;;
            analysis) OPT_X86_EDGE_AI_ANALYSIS="$([ "${OPT_X86_EDGE_AI_ANALYSIS}" = yes ] && echo no || echo yes)" ;;
            tts)     OPT_EDGE_AI_TTS="$([ "${OPT_EDGE_AI_TTS}" = yes ] && echo no || echo yes)" ;;
            runtime) OPT_EDGE_AI_RUNTIME="$([ "${OPT_EDGE_AI_RUNTIME}" = ollama ] && echo vllm || echo ollama)" ;;
            models)  OPT_EDGE_AI_MODELS="$(ui_input "Preload models" "Comma list of model tags to preload (e.g. llama3.2:3b,nomic-embed-text; empty = builder default)" "${OPT_EDGE_AI_MODELS}")" ;;
            default) OPT_EDGE_AI_MODEL_DEFAULT="$(ui_input "Default model" "Model returned when a request omits one (empty = builder default)" "${OPT_EDGE_AI_MODEL_DEFAULT}")" ;;
            back|"") save_conf; return 0 ;;
        esac
        save_conf
    done
}

# ── OPTIONAL services catalog (the user-level slugs from
# specs/cluster/optional-services.yaml). One checklist -> --optional-services
# "<list>" on cluster roles; checking 'games' also emits --enable-games (games is
# opt-in). character-studio HERE supersedes the older lone toggle — the two are
# kept in sync both ways (see services_sync_charstudio).
SERVICE_SLUGS=(akkoma tuwunel phpbb games owncast tube character-studio)

# Keep the services checklist and the lone Character Studio toggle consistent:
# the checklist is authoritative once SET, so flipping the toggle edits the list
# membership; an untouched checklist (OPT_SERVICES empty) leaves the toggle to
# its original --with-character-studio behavior.
services_sync_charstudio() {
    [ -z "${OPT_SERVICES}" ] && return 0
    local svc=",${OPT_SERVICES},"
    svc="${svc/,none,/,}"
    svc="${svc/,character-studio,/,}"
    [ "${OPT_CHARACTER_STUDIO}" = yes ] && svc="${svc}character-studio,"
    svc="${svc#,}"; svc="${svc%,}"
    OPT_SERVICES="${svc:-none}"
}

services_screen() {
    # Current selection: saved list, or (untouched) the builder default — with the
    # legacy lone character-studio toggle migrated in as a pre-checked box.
    local cur
    if [ -z "${OPT_SERVICES}" ]; then
        cur="akkoma,tuwunel,phpbb"
        [ "${OPT_CHARACTER_STUDIO}" = yes ] && cur="${cur},character-studio"
    elif [ "${OPT_SERVICES}" = none ]; then
        cur=""
    else
        cur="${OPT_SERVICES}"
    fi
    local -a rows=(); local s state
    local -A desc=(
        [akkoma]="akkoma ............ Mastodon-compatible social (homeserver)"
        [tuwunel]="tuwunel ........... Matrix homeserver"
        [phpbb]="phpbb ............. forum"
        [games]="games ............. Game Studio + games.<domain> (OPT-IN)"
        [owncast]="owncast ........... live streaming"
        [tube]="tube .............. LocalTube video"
        [character-studio]="character-studio .. Character Studio (VN) frontend remote"
    )
    for s in "${SERVICE_SLUGS[@]}"; do
        case ",${cur}," in *,"${s}",*) state=on ;; *) state=off ;; esac
        rows+=("${s}" "${desc[${s}]}" "${state}")
    done
    local sel
    sel="$(ui_checklist "Optional services" \
        "OPTIONAL user-level services baked onto CLUSTER images (defaults: akkoma+tuwunel+phpbb ON; games/owncast/tube/character-studio OFF). Unchecked slugs are pruned from the baked GitOps tree:" \
        "${rows[@]}")" || return 0
    # space-separated tags -> the persisted comma list ('' selection = EXPLICIT none)
    set -- ${sel}
    if [ "$#" -eq 0 ]; then
        OPT_SERVICES="none"
    else
        OPT_SERVICES="$(IFS=,; printf '%s' "$*")"
    fi
    # the checklist supersedes the lone Character Studio toggle — mirror it
    case ",${OPT_SERVICES}," in
        *,character-studio,*) OPT_CHARACTER_STUDIO=yes ;;
        *)                    OPT_CHARACTER_STUDIO=no ;;
    esac
    save_conf
}

# Advanced branding: per-piece artwork/palette OVERRIDES layered on top of the
# brand profile / --theme preset (which stay as-is; empty = keep the preset piece).
branding_screen() {
    while true; do
        local c
        c="$(ui_menu "Advanced branding" "Per-piece overrides on top of the brand profile / theme preset (empty = preset):" \
            wallpaper "Wallpaper ........... ${OPT_BR_WALLPAPER:-<preset>}" \
            grubbg    "GRUB background ..... ${OPT_BR_GRUB_BG:-<preset>}" \
            loginbg   "Login background .... ${OPT_BR_LOGIN_BG:-<preset>}" \
            logo      "Brand logo .......... ${OPT_BR_LOGO:-<preset>}" \
            accent    "Accent color ........ ${OPT_BR_ACCENT:-<preset>}" \
            scheme    "Color scheme ........ ${OPT_BR_SCHEME:-<preset>}" \
            back      "‹ back")" || return 0
        case "${c}" in
            wallpaper) OPT_BR_WALLPAPER="$(ui_input "Wallpaper" "Wallpaper image FILE (--wallpaper; empty = preset)" "${OPT_BR_WALLPAPER}")" ;;
            grubbg)    OPT_BR_GRUB_BG="$(ui_input "GRUB background" "GRUB background image FILE (--grub-background; empty = preset)" "${OPT_BR_GRUB_BG}")" ;;
            loginbg)   OPT_BR_LOGIN_BG="$(ui_input "Login background" "Login/greeter background FILE (--login-background; empty = preset)" "${OPT_BR_LOGIN_BG}")" ;;
            logo)      OPT_BR_LOGO="$(ui_input "Brand logo" "Brand logo image FILE (--brand-logo; empty = preset)" "${OPT_BR_LOGO}")" ;;
            accent)    OPT_BR_ACCENT="$(ui_input "Accent color" "Accent color '#RRGGBB' (--accent-color; empty = preset)" "${OPT_BR_ACCENT}")" ;;
            scheme)    OPT_BR_SCHEME="$(ui_input "Color scheme" "Color scheme FILE.colors (--color-scheme; empty = preset)" "${OPT_BR_SCHEME}")" ;;
            back|"")   save_conf; return 0 ;;
        esac
        save_conf
    done
}

# Home provisioning: how the installed user's $HOME comes to be on the standalone
# and tailnet CLIENT desktops (create fresh / adopt in place / unpack a bundled
# archive / restore an encrypted backup) + the optional source-code seed.
home_screen() {
    # Optional arg 'noseed' (the unaffiliated desktop): hide the source-code seed
    # row — --home-seed-code seeds the Snapdragon stack and is a hard conflict there.
    local noseed="${1:-}"
    while true; do
        local c
        local -a rows=(
            mode    "Home mode ........... ${OPT_HOME_MODE:-<builder default>}   (create|adopt|archive|restore)"
            device  "Home device ......... ${OPT_HOME_DEVICE:-<none>}   (adopt: LABEL=…|UUID=…|/dev/…)"
            backup  "Home backup ......... ${OPT_HOME_BACKUP:-<none>}   (restore: FILE | auto)"
            enc     "Encrypted home ...... ${OPT_HOME_ENCRYPTED}   (per-user eCryptfs on top of LUKS2)"
        )
        [ "${noseed}" != noseed ] && rows+=(seed "Seed source code .... ${OPT_HOME_SEED:-none}   (none|repos|stack|mesh)")
        rows+=(
            archive "Bundle home archive . ${OPT_HOME_ARCHIVE:-<none>}   (scripts/archive-home.sh tarball)"
            back    "‹ back"
        )
        c="$(ui_menu "Home provisioning" "How the installed user's \$HOME is provisioned (standalone + client desktops only):" "${rows[@]}")" || return 0
        case "${c}" in
            mode)   local m
                    m="$(ui_menu "Home mode" "--home-mode — how the user's home is provisioned:" \
                        default "builder default (create; archive when one is bundled)" \
                        create  "create  — fresh home" \
                        adopt   "adopt   — USE an existing home in place (needs Home device)" \
                        archive "archive — unpack the bundled home archive" \
                        restore "restore — decrypt+unpack an encrypted backup (needs Home backup)")" || m=""
                    case "${m}" in default|"") OPT_HOME_MODE="" ;; *) OPT_HOME_MODE="${m}" ;; esac ;;
            device) OPT_HOME_DEVICE="$(ui_input "Home device" "adopt: the existing home's LABEL=…|UUID=…|/dev/… (--home-device; empty = none)" "${OPT_HOME_DEVICE}")" ;;
            backup) OPT_HOME_BACKUP="$(ui_input "Home backup" "restore: the encrypted backup FILE, or 'auto' to find it on a USB (--home-backup; empty = none)" "${OPT_HOME_BACKUP}")" ;;
            enc)    OPT_HOME_ENCRYPTED="$([ "${OPT_HOME_ENCRYPTED}" = yes ] && echo no || echo yes)" ;;
            seed)   local sd
                    sd="$(ui_menu "Seed source code" "--home-seed-code — drop the Snapdragon source tree into ~/snapdragon-stack:" \
                        none  "none  — no source seed (default)" \
                        repos "repos — just the code" \
                        stack "stack — code + docker-compose stack runner" \
                        mesh  "mesh  — code + dockerized tailnet mesh node")" || sd=""
                    case "${sd}" in none|"") OPT_HOME_SEED="" ;; *) OPT_HOME_SEED="${sd}" ;; esac ;;
            archive) OPT_HOME_ARCHIVE="$(ui_input "Home archive" "Bundle a \$HOME tarball (scripts/archive-home.sh) into the installer ISO (--include-home-archive; empty = none)" "${OPT_HOME_ARCHIVE}")" ;;
            back|"") save_conf; return 0 ;;
        esac
        save_conf
    done
}

options_screen() {
    while true; do
        local resume_l omni_l frite_fleet_l jetson_fleet_l orangepi5_fleet_l pen_l
        resume_l="$([ "${OPT_RESUME}" = yes ] && echo on || echo off)"
        omni_l="$([ "${OPT_OMNIBUS}" = yes ] && echo on || echo off)"
        frite_fleet_l="$([ "${OPT_FRITE_FLEET}" = yes ] && echo on || echo off)"
        jetson_fleet_l="$([ "${OPT_JETSON_FLEET}" = yes ] && echo on || echo off)"
        orangepi5_fleet_l="$([ "${OPT_ORANGEPI5_FLEET}" = yes ] && echo on || echo off)"
        pen_l="$([ "${OPT_PENTEST}" = yes ] && echo on || echo off)"
        local choice
        choice="$(ui_menu "Options" "Adjust build options (saved for next time):" \
            path     "Build path .......... ${OPT_PATH}  (docker | native)" \
            env      "Environment ......... ${OPT_ENV}   (test | prod)" \
            jobs     "Parallel jobs ....... ${OPT_JOBS}" \
            workdir  "Work / output dir ... ${OPT_WORK_DIR}" \
            brand    "Brand ............... ${OPT_BRAND:-<default>}" \
            domain   "Domain override ..... ${OPT_DOMAIN:-<from brand>}" \
            resume   "Resume sysroots ..... ${resume_l}   (full-fleet build only)" \
            omnibus  "x86 omnibus role .... ${omni_l}   (adds omnibus to full fleet)" \
            fritefleet "Frite in full fleet . ${frite_fleet_l}   (adds Frite to full fleet; FRITE=1)" \
            jetsonfleet "Jetson in full fleet  ${jetson_fleet_l}   (adds Jetson to full fleet; JETSON=1)" \
            orangepi5fleet "Orange Pi 5 in fleet  ${orangepi5_fleet_l}   (adds Orange Pi 5 to full fleet; ORANGEPI5=1; EXPERIMENTAL)" \
            pentest  "OWASP pen-test ...... ${pen_l}   (full-fleet build only)" \
            edgeai   "Edge-AI service ..... $([ "${OPT_X86_EDGE_AI}" = yes ] && echo on || echo off)   (be+gpu/omnibus; edge_ai role always on)" \
            services "Optional services ... ${OPT_SERVICES:-<default: akkoma,tuwunel,phpbb>}" \
            tor      "Tor v3 onion ........ $([ "${OPT_TOR_ONION}" = yes ] && echo on || echo off)   (node service; exposes fe-gateway as .onion; default off)" \
            charstudio "Character Studio (VN) $([ "${OPT_CHARACTER_STUDIO}" = yes ] && echo on || echo off)   (frontend remote at /character-studio; default off)" \
            advbrand "Advanced branding ... $({ [ -n "${OPT_BR_WALLPAPER}${OPT_BR_GRUB_BG}${OPT_BR_LOGIN_BG}${OPT_BR_LOGO}${OPT_BR_ACCENT}${OPT_BR_SCHEME}" ] && echo overrides; } || echo '<preset>')   (wallpaper/GRUB/login/logo/accent/scheme)" \
            home     "Home provisioning ... ${OPT_HOME_MODE:-<default>}   (standalone/client desktops)" \
            instui   "Installer UI ........ ${OPT_INSTALLER_UI:-<builder default>}   (cli|ncurses|calamares|all)" \
            imgflags "Image format flags .. ${OPT_IMGFLAGS:-<both .img + .iso>}" \
            extraflags "Extra builder flags . ${OPT_EXTRA_FLAGS:-<none>}   (passed VERBATIM — escape hatch)" \
            rootlogin "Root SSH login ...... ${OPT_ROOT_LOGIN}   (no=hardened | prohibit-password | yes)" \
            back     "‹ back to main menu")" || return 0
        case "${choice}" in
            path)    OPT_PATH="$([ "${OPT_PATH}" = docker ] && echo native || echo docker)" ;;
            env)     OPT_ENV="$([ "${OPT_ENV}" = test ] && echo prod || echo test)" ;;
            jobs)    OPT_JOBS="$(ui_input "Jobs" "Parallel build jobs (-j)" "${OPT_JOBS}")" ;;
            workdir) OPT_WORK_DIR="$(ui_input "Work dir" "Output / work directory" "${OPT_WORK_DIR}")" ;;
            brand)   OPT_BRAND="$(ui_input "Brand" "Brand profile (brands/<name>.conf; empty = default)" "${OPT_BRAND}")" ;;
            domain)  OPT_DOMAIN="$(ui_input "Domain" "Cluster domain override (empty = brand default)" "${OPT_DOMAIN}")" ;;
            resume)  OPT_RESUME="$([ "${OPT_RESUME}" = yes ] && echo no || echo yes)" ;;
            omnibus) OPT_OMNIBUS="$([ "${OPT_OMNIBUS}" = yes ] && echo no || echo yes)" ;;
            fritefleet) OPT_FRITE_FLEET="$([ "${OPT_FRITE_FLEET}" = yes ] && echo no || echo yes)" ;;
            jetsonfleet) OPT_JETSON_FLEET="$([ "${OPT_JETSON_FLEET}" = yes ] && echo no || echo yes)" ;;
            orangepi5fleet) OPT_ORANGEPI5_FLEET="$([ "${OPT_ORANGEPI5_FLEET}" = yes ] && echo no || echo yes)" ;;
            pentest) OPT_PENTEST="$([ "${OPT_PENTEST}" = yes ] && echo no || echo yes)" ;;
            edgeai)  edge_ai_options_screen ;;
            services) services_screen ;;
            tor)     OPT_TOR_ONION="$([ "${OPT_TOR_ONION}" = yes ] && echo no || echo yes)" ;;
            charstudio) OPT_CHARACTER_STUDIO="$([ "${OPT_CHARACTER_STUDIO}" = yes ] && echo no || echo yes)"
                        services_sync_charstudio ;;   # the checklist mirrors the toggle
            advbrand) branding_screen ;;
            home)    home_screen ;;
            instui)  local iu
                     iu="$(ui_menu "Installer UI" "Installer front-ends offered as live-ISO boot entries (--installer-ui):" \
                         default   "builder default (standalone = all, others = cli)" \
                         cli       "cli       — text installer" \
                         ncurses   "ncurses   — dialog/ncurses installer" \
                         calamares "calamares — graphical Qt installer (Ubuntu-style)" \
                         all       "all       — every front-end")" || iu=""
                     case "${iu}" in default|"") OPT_INSTALLER_UI="" ;; *) OPT_INSTALLER_UI="${iu}" ;; esac ;;
            imgflags) OPT_IMGFLAGS="$(ui_input "Image flags" "IMG_FLAGS (e.g. --no-iso, --no-img, empty = both)" "${OPT_IMGFLAGS}")" ;;
            extraflags) OPT_EXTRA_FLAGS="$(ui_input "Extra builder flags" "Extra builder flags, threaded VERBATIM onto the single-role builder invocation (x86/jetson/frite/orangepi5/orangepizero2/rpi-<role> via STANDALONE_FLAGS; the rpi/x86/omnibus FLEET targets — multiple roles per build — via IMG_FLAGS instead, since a standalone-shaped flag has no single role to apply to there). The escape hatch guaranteeing all-options-in-all-menus. Empty = none" "${OPT_EXTRA_FLAGS}")" ;;
            rootlogin) case "${OPT_ROOT_LOGIN}" in
                           no) OPT_ROOT_LOGIN=prohibit-password ;;
                           prohibit-password) OPT_ROOT_LOGIN=yes ;;
                           *) OPT_ROOT_LOGIN=no ;;
                       esac ;;
            back|"") save_conf; return 0 ;;
        esac
        save_conf
    done
}

# Build a single role (pick arch then role).
single_role_screen() {
    local arch role board
    arch="$(ui_menu "Single role" "Which architecture?" \
        rpi "Raspberry Pi 5 / 4 / 3 (arm64 mesh node OR desktop; --board rpi5|rpi4|rpi3)" \
        x86 "x86-64 (amd64 node / GPU host / client)" \
        jetson "Jetson Orin Nano (arm64, EXPERIMENTAL — hardware validation pending)" \
        orangepi5 "Orange Pi 5 / 5 Plus (arm64, EXPERIMENTAL — hardware validation pending)" \
        orangepizero2 "Orange Pi Zero 2 — HEADLESS APPLIANCE (arm64, EXPERIMENTAL — no desktop mode ever)" \
        back "‹ back")" || return 0
    case "${arch}" in
        rpi)
            role="$(ui_menu "Pi role" "Pick a Raspberry Pi role:" \
                pki "pki      — cluster PKI / control" \
                backend "backend  — backend services node" \
                frontend "frontend — gateway / UI node" \
                desktop "desktop  — arm64 client image (compose with --standalone for FDE)" \
                back "‹ back")" || return 0
            [ "${role}" = back ] && return 0
            board="$(ui_menu "Pi board" "Raspberry Pi board (--board; current: ${OPT_RPI_BOARD}):" \
                rpi5 "rpi5 — Raspberry Pi 5 (BCM2712, Cortex-A76) — DEFAULT" \
                rpi4 "rpi4 — Raspberry Pi 4 (BCM2711, Cortex-A72)" \
                rpi3 "rpi3 — Raspberry Pi 3 (BCM2837, Cortex-A53, 1GB RAM) — DESKTOP ROLE ONLY" \
                back "‹ back")" || return 0
            [ "${board}" = back ] && return 0
            # rpi3 is desktop-only — the board picker is offered for every role
            # (simpler/safer than gating it to the desktop sub-path only), so
            # nudge here with a non-blocking warning; the builder itself is the
            # AUTHORITATIVE safety net either way (hard-errors on any other role).
            if [ "${board}" = rpi3 ] && [ "${role}" != desktop ]; then
                warn "--board rpi3 only composes onto --role desktop (1GB RAM is not enough headroom for the k8s cluster-node stack) — the build will hard-error for role '${role}'. Pick 'desktop', or choose rpi4/rpi5 for ${role}."
            fi
            OPT_RPI_BOARD="${board}"
            # --standalone only composes onto --role desktop — the masked secrets
            # prompt is only meaningful there (a cluster-node role would just
            # ignore/reject --local-pass/--luks-pass).
            [ "${role}" = desktop ] && arm_secrets_prompt "Pi ${role} (${OPT_RPI_BOARD})"
            save_conf
            build_make_cmd "rpi-${role}" "Pi ${role} (${OPT_RPI_BOARD}, ${OPT_PATH}, ENV=${OPT_ENV})" 1
            launch_build ;;
        x86)
            role="$(ui_menu "x86 role" "Pick an x86 role:" \
                pki "pki     — cluster PKI / control" \
                be "be      — backend node" \
                fe "fe      — frontend / gateway node" \
                be+gpu "be+gpu  — backend + GPU host (the e2e GPU node)" \
                omnibus "omnibus — all-in-one single node" \
                edge_ai "edge_ai — GPU inference node (OpenAI model API to the mesh)" \
                laptop "laptop  — amd64 laptop desktop image" \
                chromebook "chromebook — coreboot/UEFI Chromebook DESKTOP image (ADR-16)" \
                desktop "desktop — full desktop client image" \
                standalone-thin "★ standalone-thin — hardened NVIDIA desktop (LXDE; no mesh/SSO)" \
                standalone-thick "★ standalone-thick — most-capable Plasma NVIDIA desktop (no mesh/SSO)" \
                standalone-unaffiliated "★ standalone-unaffiliated — UNAFFILIATED desktop: plain hardened Gentoo (thick/Plasma weight), NO Snapdragon" \
                back "‹ back")" || return 0
            [ "${role}" = back ] && return 0
            case "${role}" in
                standalone-thin|standalone-thick|standalone-unaffiliated) standalone_screen "${role}" ;;
                *) build_make_cmd "x86-${role}" "x86 ${role} (${OPT_PATH}, ENV=${OPT_ENV})" 1
                   launch_build ;;
            esac ;;
        jetson)
            # NVIDIA Jetson Orin — arm64 Tegra edge-AI platform (specs-jetson/).
            # EXPERIMENTAL: the platform bring-up is hardware-gated (validation
            # pending); dispatches the Makefile jetson-<role> targets. NOTE: the
            # Options screen's cluster services / edge-AI model / branding-override
            # knobs are x86-only flags and do NOT apply here — any Jetson builder
            # flag stays reachable via 'Extra builder flags' (the escape hatch).
            role="$(ui_menu "Jetson role" "Jetson Orin role (arm64 Tegra, EXPERIMENTAL — hardware validation pending).
x86-only options (cluster services, edge-AI models, branding overrides) do not apply; use Extra builder flags for Jetson flags:" \
                edge_ai "edge_ai  — GPU inference node (the headline Jetson role)" \
                full "full     — full-stack node (all namespaces on the board)" \
                gpu-host "gpu-host — GPU host only" \
                desktop "desktop  — arm64 desktop client image" \
                back "‹ back")" || return 0
            [ "${role}" = back ] && return 0
            board="$(ui_menu "Jetson board" "Orin module/carrier (--board; current: ${OPT_JETSON_BOARD}):" \
                orin-nano "orin-nano     — Orin Nano [Super] devkit, 8GB (DEFAULT)" \
                orin-nano-4gb "orin-nano-4gb — Orin Nano 4GB, devkit carrier (UNTESTED)" \
                orin-nx-8gb "orin-nx-8gb   — Orin NX 8GB, devkit carrier (UNTESTED)" \
                orin-nx-16gb "orin-nx-16gb  — Orin NX 16GB, devkit carrier (UNTESTED)" \
                back "‹ back")" || return 0
            [ "${board}" = back ] && return 0
            OPT_JETSON_BOARD="${board}"
            # --standalone only composes onto --role desktop, same reasoning as rpi5.
            [ "${role}" = desktop ] && arm_secrets_prompt "Jetson ${role} (${OPT_JETSON_BOARD})"
            save_conf
            build_make_cmd "jetson-${role}" "Jetson ${role} (${OPT_JETSON_BOARD}, ${OPT_PATH}, ENV=${OPT_ENV}) [EXPERIMENTAL]" 1
            launch_build ;;
        orangepi5)
            # Orange Pi 5 / Orange Pi 5 Plus — arm64 Rockchip RK3588/RK3588S
            # light desktop (specs-orangepi5/). EXPERIMENTAL: hardware
            # validation pending; dispatches the Makefile orangepi5 target.
            # ONE role (a client desktop, like Frite) — no --role picker, just
            # board + flavor. NOTE: the Options screen's cluster services /
            # edge-AI model / branding-override knobs are x86-only flags and do
            # NOT apply here; any Orange Pi 5 builder flag (incl.
            # --standalone/--encrypt-root) stays reachable via 'Extra builder
            # flags' (the escape hatch).
            local flavor
            board="$(ui_menu "Orange Pi 5 board" "Board variant (--board; current: ${OPT_ORANGEPI5_BOARD}). EXPERIMENTAL — hardware validation pending, see specs-orangepi5/README.md:" \
                orange-pi-5-plus "orange-pi-5-plus — RK3588: dual 2.5GbE, PCIe3.0x4 NVMe, dual HDMI+HDMI-in (DEFAULT)" \
                orange-pi-5 "orange-pi-5      — RK3588S: fewer PCIe lanes, single NIC, single HDMI" \
                back "‹ back")" || return 0
            [ "${board}" = back ] && return 0
            OPT_ORANGEPI5_BOARD="${board}"
            flavor="$(ui_menu "Orange Pi 5 flavor" "Image flavor (--flavor; current: ${OPT_ORANGEPI5_FLAVOR}):" \
                both "both       — live + installer (DEFAULT)" \
                live "live       — ephemeral USB/microSD boot" \
                installer "installer  — writes to eMMC/microSD/NVMe" \
                back "‹ back")" || return 0
            [ "${flavor}" = back ] && return 0
            OPT_ORANGEPI5_FLAVOR="${flavor}"
            arm_secrets_prompt "Orange Pi 5 ${board}"
            save_conf
            build_make_cmd orangepi5 "Orange Pi 5 ${board} (${flavor}, ${OPT_PATH}, ENV=${OPT_ENV}) [EXPERIMENTAL]" 1
            launch_build ;;
        orangepizero2)
            # Orange Pi Zero 2 — arm64 Allwinner H616 HEADLESS APPLIANCE
            # (specs-orangepi-zero2/). EXPERIMENTAL: hardware validation
            # pending; dispatches the Makefile orangepizero2 target. ONE role
            # (a headless appliance, NEVER a desktop — see
            # specs-orangepi-zero2/README.md for why) — no --role picker, no
            # board picker (a single board, unlike Frite/Orange-Pi-5), just a
            # flavor picker. NOTE: the Options screen's cluster services /
            # edge-AI model / branding-override knobs are x86-only flags and do
            # NOT apply here; any Orange Pi Zero 2 builder flag (incl.
            # --standalone/--encrypt-root) stays reachable via 'Extra builder
            # flags' (the escape hatch).
            local flavor
            flavor="$(ui_menu "Orange Pi Zero 2 flavor" "Image flavor (--flavor; current: ${OPT_ORANGEPIZERO2_FLAVOR}). EXPERIMENTAL — hardware validation pending, see specs-orangepi-zero2/README.md:" \
                both "both       — live + installer (DEFAULT)" \
                live "live       — ephemeral microSD/USB boot" \
                installer "installer  — writes to microSD/USB" \
                back "‹ back")" || return 0
            [ "${flavor}" = back ] && return 0
            OPT_ORANGEPIZERO2_FLAVOR="${flavor}"
            arm_secrets_prompt "Orange Pi Zero 2 headless appliance"
            save_conf
            build_make_cmd orangepizero2 "Orange Pi Zero 2 headless appliance (${flavor}, ${OPT_PATH}, ENV=${OPT_ENV}) [EXPERIMENTAL]" 1
            launch_build ;;
        *) return 0 ;;
    esac
}

# Standalone hardened NVIDIA desktop: collect the local user + password, NVIDIA
# driver, Steam, media-data and optional unlock factor, then launch. Passwords are
# prompted fresh (never persisted); the LUKS root passphrase is set at INSTALL time.
standalone_screen() {
    local role="$1" choice weight unaff=no prompt
    weight="thin"; [ "${role}" = standalone-thick ] && weight="full (most-capable Plasma)"
    if [ "${role}" = standalone-unaffiliated ]; then
        unaff=yes; weight="UNAFFILIATED (plain Gentoo, thick weight)"
    fi
    prompt="Hardened NVIDIA standalone desktop — no mesh, no SSO, local login. Installed system is LUKS2-encrypted (you set the root passphrase at install)."
    [ "${unaff}" = yes ] && prompt="UNAFFILIATED plain hardened Gentoo desktop — ZERO Snapdragon affiliation: no brand, no theme, no source seed, no mesh/SSO. The role presets the neutral identity; branding/seed options are hidden (they hard-conflict). Installed system is LUKS2-encrypted (you set the root passphrase at install)."
    while :; do
        local media_l home_l
        media_l="$([ "${OPT_SA_MEDIA}" = yes ] && echo "ON (/media Vaults+Steam auto-detect)" || echo OFF)"
        # unaffiliated: --home-seed-code is a hard conflict — the seed knob is
        # neither shown in the label nor offered in the home sub-screen.
        home_l="mode=${OPT_HOME_MODE:-default} seed=${OPT_HOME_SEED:-none} enc=${OPT_HOME_ENCRYPTED}"
        [ "${unaff}" = yes ] && home_l="mode=${OPT_HOME_MODE:-default} enc=${OPT_HOME_ENCRYPTED}   (no source seed)"
        local -a items=(
            user    "Local user ......... ${OPT_SA_USER}"
            pass    "Local password ..... $([ -n "${SA_LOCAL_PASS}" ] && echo '(set)' || echo '(unset → random at first boot)')"
            gpu     "GPU driver ......... ${OPT_SA_GPU}"
            steam   "Steam delivery ..... ${OPT_SA_STEAM}  (library on /media/Steam)"
            media   "Media data ......... ${media_l}"
            medialabel "Media label ........ ${OPT_SA_MEDIA_LABEL:-<content-scan>}   (match data device by FS LABEL)"
            home    "Home provisioning .. ${home_l}"
            keyfile "Keyfile unlock ..... ${OPT_SA_KEYFILE}   (boot=LUKS keyslot / login=PAM)"
            yubikey "YubiKey unlock ..... ${OPT_SA_YUBIKEY}   (boot=FIDO2 / login=pam_u2f)"
        )
        # branding theme: hidden for the unaffiliated role (hard conflict).
        [ "${unaff}" = no ] && items+=(theme "Branding theme ..... ${OPT_SA_THEME}")
        items+=(
            security "Security stack .... proxy=${OPT_SA_PROXY} snort=${OPT_SA_SNORT} aide=${OPT_SA_AIDE}"
            kernel  "Kernel built-in .... ${OPT_SA_KBUILTIN}   (=y vs modules)"
            egress  "Egress VPN ......... ${OPT_SA_EGRESS:-<none>}"
            luks    "Unattended LUKS pass $([ -n "${SA_LUKS_PASS}" ] && echo '(set — advanced)' || echo '(installer prompts — recommended)')"
            build   "★ BUILD this image (live ISO + stage4 + .fs.tar.xz + installer ISO)"
            back    "‹ back"
        )
        choice="$(ui_menu "Standalone ${weight}" "${prompt}" "${items[@]}")" || return 0
        case "${choice}" in
            user)    OPT_SA_USER="$(ui_input "User" "Local login user name" "${OPT_SA_USER}")" ;;
            pass)    SA_LOCAL_PASS="$(ui_password "Password" "Password for ${OPT_SA_USER} (blank = random one-time at first boot)")" ;;
            gpu)     OPT_SA_GPU="$(ui_menu "GPU driver" "Video card / driver (FREE = open, no EULA — the default):" \
                         all-free "All free (any GPU; NVIDIA=nouveau) — default" \
                         nvidia-free "NVIDIA free (nouveau)" \
                         nvidia "NVIDIA proprietary (nvidia-drivers)" \
                         amd-free "AMD/ATI free (amdgpu/radeonsi)" \
                         amd-pro "AMD/ATI pro (+ AMDGPU-PRO Vulkan/OpenCL)" \
                         intel-free "Intel free (i915/iris)" \
                         intel-pro "Intel pro (+ compute/media stack)")" ;;
            steam)   OPT_SA_STEAM="$(ui_menu "Steam" "Steam delivery:" native "Native (default; steam-overlay + multilib)" flatpak "Flatpak (no multilib)" none "Don't install Steam")" ;;
            media)   OPT_SA_MEDIA="$([ "${OPT_SA_MEDIA}" = yes ] && echo no || echo yes)" ;;
            medialabel) OPT_SA_MEDIA_LABEL="$(ui_input "Media label" "Filesystem LABEL of the media data device (--media-label; empty = content-scan for the Steam/Vaults marker dirs)" "${OPT_SA_MEDIA_LABEL}")" ;;
            home)    if [ "${unaff}" = yes ]; then home_screen noseed; else home_screen; fi ;;
            keyfile) OPT_SA_KEYFILE="$(ui_menu "Keyfile factor" "Generate a keyfile unlock factor for:" none "none" boot "boot (extra LUKS keyslot)" login "login (PAM)")" ;;
            yubikey) OPT_SA_YUBIKEY="$(ui_menu "YubiKey factor" "Enroll a FIDO2/YubiKey factor for:" none "none" boot "boot (LUKS FIDO2)" login "login (pam_u2f)")" ;;
            theme)   OPT_SA_THEME="$(ui_menu "Branding theme" "Boot screen / login / wallpaper / accent:" \
                         none "None (stock look)" $(for t in "${SCRIPT_DIR}"/../specs-x86/branding/themes/*/; do [ -d "$t" ] && b="$(basename "$t")" && echo "$b" "$b theme"; done))" ;;
            security) while :; do
                          local sc
                          sc="$(ui_menu "Security stack" "Toggle each (Squid+Privoxy are desktop-only; Snort all images; AIDE opt-in):" \
                              proxy "Squid+Privoxy+Firefox proxy: ${OPT_SA_PROXY}" \
                              snort "Snort IDS: ${OPT_SA_SNORT}" \
                              aide  "AIDE file-integrity IDS: ${OPT_SA_AIDE}" \
                              done  "‹ done")" || break
                          case "${sc}" in
                              proxy) OPT_SA_PROXY="$([ "${OPT_SA_PROXY}" = yes ] && echo no || echo yes)" ;;
                              snort) OPT_SA_SNORT="$([ "${OPT_SA_SNORT}" = yes ] && echo no || echo yes)" ;;
                              aide)  OPT_SA_AIDE="$([ "${OPT_SA_AIDE}" = yes ] && echo no || echo yes)" ;;
                              *)     break ;;
                          esac
                      done ;;
            kernel)  OPT_SA_KBUILTIN="$([ "${OPT_SA_KBUILTIN}" = yes ] && echo no || echo yes)" ;;
            egress)  OPT_SA_EGRESS="$(ui_input "Egress VPN" "Path to a WireGuard .conf / OpenVPN .ovpn (empty = none)" "${OPT_SA_EGRESS}")" ;;
            luks)    SA_LUKS_PASS="$(ui_password "Unattended LUKS" "Bake an unattended LUKS passphrase into the installer ISO (ADVANCED; blank = installer prompts at install)")" ;;
            build)   save_conf
                     if [ "${unaff}" = yes ]; then
                         build_make_cmd "x86-${role}" "x86 ${role} UNAFFILIATED plain Gentoo desktop (${OPT_PATH}, ENV=${OPT_ENV})" 1
                     else
                         build_make_cmd "x86-${role}" "x86 ${role} hardened NVIDIA standalone (${OPT_PATH}, ENV=${OPT_ENV})" 1
                     fi
                     launch_build; return 0 ;;
            back|"") save_conf; return 0 ;;
        esac
        save_conf
    done
}

# ── STEP 1 — the four-choice opening screen (Studio ModePage parity) ────────────
# A THIN clarity/router layer on TOP of the existing screens: the labels mirror the
# Studio GUI reference (studio/snapdragon_studio/gui/pages/mode.py) verbatim so the
# build-matrix TAXO parity check has ONE golden set. It reorganises NAVIGATION only —
# the three IMAGE choices funnel into the EXISTING screens (build_screen /
# single_role_screen / standalone_screen), each of which already calls build_make_cmd
# verbatim, so emission stays byte-identical. The fourth choice (Local Docker mesh)
# builds NO image and never touches build_make_cmd. The Enterprise-phone choice
# (phone_screen) likewise builds NO image — it drives scripts/phone-wizard.sh and is
# NOT part of the four-label golden taxonomy (it sits outside mode.py's ModePage).
mode_screen() {
    local choice
    while :; do
        choice="$(ui_menu "What do you want to build?" \
            "Pick one. Three of these build an image; Local Docker mesh instead runs a mesh on THIS machine right now." \
            meshnode   "Mesh node — build server node image(s) for a mesh on dedicated hardware" \
            localmesh  "Local Docker mesh — run a mesh on THIS machine in Docker (no image built)" \
            client     "Mesh desktop client — a branded desktop that JOINS an existing mesh (tailnet + SSO)" \
            standalone "Standalone Gentoo desktop — hardened personal / UNAFFILIATED desktop (no mesh/SSO)" \
            phone      "Enterprise phone — flash a USB Pixel with VERIFIED GrapheneOS + enroll it in the mesh (no image built)" \
            advanced   "Advanced — all build targets & fleet options (the full menu)" \
            back "‹ back to main menu")" || return 0
        # NOTE: the four choice LABELS above are the single golden source of the
        # taxonomy (mirrored from mode.py). The build-matrix TAXO bucket anchors to THIS
        # ui_menu item shape (choice-tag + quoted label, e.g. `localmesh  "Local Docker
        # mesh …`), NOT to a whole-file substring — the "Local Docker mesh" string also
        # appears in the prompt sentence and the local_mesh_screen dialog titles below,
        # so only the anchored item match makes dropping an opening choice from this list
        # a non-vacuous parity FAIL.
        case "${choice}" in
            # → the fleet + cluster single-role image builds (the existing build_screen
            # offers all/everything/rpi/x86/one/omni/frite verbatim).
            meshnode)   build_screen ;;
            # → the ONE non-build choice; runs a dockerized node via the shared Qt-free
            # entrypoint. Builds no image.
            localmesh)  local_mesh_screen ;;
            # → the client-desktop single-role paths (x86 laptop/chromebook/desktop, rpi
            # desktop, frite, orangepi5/zero2) — all of which call build_make_cmd verbatim.
            client)     single_role_screen ;;
            # → the x86 standalone screen; the ARM standalone posture stays reachable via
            # single_role_screen's desktop roles + arm_secrets_prompt (Advanced too).
            standalone) single_role_screen ;;
            # → the SECOND non-build choice: the enterprise-phone driver (flash a real
            # Pixel handset + enroll it in the mesh). Like localmesh it never touches
            # build_make_cmd — the driver owns ALL the logic, phone_screen stays thin.
            phone)      phone_screen ;;
            # → the full build menu verbatim, the escape hatch that keeps EVERY existing
            # option/path reachable (all-options-in-all-menus).
            advanced)   build_screen ;;
            back|"")    return 0 ;;
        esac
    done
}

# ── Local Docker mesh (fourth choice) — builds NO image ─────────────────────────
# Shells the SAME Qt-free entrypoint the Studio wizard/tray drive
# (python3 -m snapdragon_studio.core.local_mesh), so the menu never reimplements
# docker compose. The auth key is entered masked (ui_password — same non-persisted
# contract as the SA_*/ARM_* secrets), written to a chmod-600 mktemp file under
# STATE_DIR for the child, then shredded. Never persisted to menu.conf.
local_mesh_screen() {
    if ! command -v python3 >/dev/null 2>&1; then
        ui_msg "Local Docker mesh" "python3 is required to run a local mesh node (it drives the shared snapdragon_studio.core.local_mesh entrypoint). Install python3 and retry."
        return 0
    fi
    local authkey="" node_name="" login_server="" choice
    while :; do
        local keyl
        keyl="$([ -n "${authkey}" ] && echo '(set)' || echo '(unset — required to start)')"
        choice="$(ui_menu "Local Docker mesh" \
            "Run a mesh on THIS machine in Docker — no image build, no server hardware. Provide a tailnet/headscale auth key; the dockerized node joins and serves locally. Masked input; never saved to ${CONF_FILE}." \
            authkey "Auth key (TS_AUTHKEY) . ${keyl}" \
            name    "Node name ............ ${node_name:-<default: snapdragon-node>}" \
            server  "Login server ......... ${login_server:-<Tailscale default coordinator>}" \
            up      "★ Start the local mesh node (docker compose up -d)" \
            stop    "Stop the local mesh node (docker compose down)" \
            status  "Status (is it running?)" \
            logs    "View recent node logs" \
            scratch "⚙ Generate & start a NEW local mesh FROM SCRATCH …" \
            back    "‹ back")" || return 0
        case "${choice}" in
            authkey) authkey="$(ui_password "Auth key" "Tailnet/headscale auth key (tskey-… ; required to start)")" ;;
            name)    node_name="$(ui_input "Node name" "Optional hostname on the tailnet (blank = snapdragon-node)" "${node_name}")" ;;
            server)  login_server="$(ui_input "Login server" "Optional self-hosted headscale URL (blank = Tailscale default)" "${login_server}")" ;;
            up|stop|status|logs)
                # menu verb -> entrypoint subcommand (only "stop" differs: -> "down")
                local sub="${choice}"; [ "${choice}" = stop ] && sub=down
                _local_mesh_run "${sub}" "${authkey}" "${node_name}" "${login_server}" ;;
            scratch) local_mesh_bootstrap_screen ;;
            back|"") return 0 ;;
        esac
    done
}

# ── Local Docker mesh FROM SCRATCH (generate creds + start a superadmin mesh) ────
# The "generate & start a NEW local mesh from scratch" path. Shells the SAME Qt-free
# entrypoint the Studio dialog drives (python3 -m
# snapdragon_studio.core.local_mesh_bootstrap), so the menu never reimplements the gen
# scripts or docker compose. NON-destructive: `plan` only previews; `up` mints creds +
# starts containers (prod additionally TTY-confirms, no bypass). The prod auth key is
# entered masked and handed over via a chmod-600 mktemp file, then shredded.
local_mesh_bootstrap_screen() {
    if ! command -v python3 >/dev/null 2>&1; then
        ui_msg "Local mesh (from scratch)" "python3 is required (it drives the shared snapdragon_studio.core.local_mesh_bootstrap entrypoint)."
        return 0
    fi
    local env="test" superadmin="superadmin" social="" domain="" authkey="" choice
    while :; do
        choice="$(ui_menu "Local mesh — from scratch" \
            "Generate ALL credentials + start a NEW superadmin-controlled mesh on THIS machine (full platform stack, seeded superadmin). Nothing runs until you pick 'up'. Creds land in the gitignored keys-out/ at runtime only." \
            env       "Environment .......... ${env}" \
            superadmin "Superadmin username .. ${superadmin}" \
            social    "Social profile ....... ${social:+on}${social:-off}" \
            domain    "Public domain (prod) . ${domain:-<brand default in test>}" \
            authkey   "Auth key (prod) ...... $([ -n "${authkey}" ] && echo '(set)' || echo '(unset)')" \
            plan      "★ Preview the plan (no side effects)" \
            up        "GENERATE creds + START from scratch" \
            down      "Stop (stack + overlay)" \
            status    "Status (is it running?)" \
            back      "‹ back")" || return 0
        case "${choice}" in
            env)       env="$(ui_menu "Environment" "test = LAN-only/offline (safe default); prod = real public domain" test "test — LAN-only / offline" prod "prod — real public domain")" || env="test"; [ -n "${env}" ] || env="test" ;;
            superadmin) superadmin="$(ui_input "Superadmin username" "The platform superadmin login to mint" "${superadmin}")"; [ -n "${superadmin}" ] || superadmin="superadmin" ;;
            social)    if [ -n "${social}" ]; then social=""; else social=1; fi ;;
            domain)    domain="$(ui_input "Public domain" "Public apex domain (required in prod; blank = brand default in test)" "${domain}")" ;;
            authkey)   authkey="$(ui_password "Auth key" "Tailnet/headscale auth key (required in prod)")" ;;
            plan|up|down|status)
                _local_mesh_bootstrap_run "${choice}" "${env}" "${superadmin}" "${social}" "${domain}" "${authkey}" ;;
            back|"") return 0 ;;
        esac
    done
}

# _local_mesh_bootstrap_run SUB ENV SUPERADMIN SOCIAL DOMAIN AUTHKEY — one child
# invocation. The auth key (when set) goes into a chmod-600 mktemp file (off the argv)
# and is shredded afterwards.
_local_mesh_bootstrap_run() {
    local sub="$1" env="$2" superadmin="$3" social="$4" domain="$5" authkey="$6"
    local -a args=("${sub}" --env "${env}" --superadmin-username "${superadmin}")
    [ -n "${social}" ] && args+=(--social)
    [ -n "${domain}" ] && args+=(--cluster-domain "${domain}")
    local keyfile=""
    if [ -n "${authkey}" ]; then
        keyfile="$(mktemp "${STATE_DIR}/bootkey.XXXXXX")" || { ui_msg "Local mesh (from scratch)" "could not create a temp file for the auth key"; return 0; }
        chmod 600 "${keyfile}" 2>/dev/null || true
        printf '%s' "${authkey}" >"${keyfile}"
        args+=(--authkey-file "${keyfile}")
    fi
    args+=(--generator-dir "${REPO_DIR}")
    local out
    out="$(PYTHONPATH="${REPO_DIR}/studio" python3 -m snapdragon_studio.core.local_mesh_bootstrap "${args[@]}" 2>&1)"
    local rc=$?
    if [ -n "${keyfile}" ]; then
        command -v shred >/dev/null 2>&1 && shred -u "${keyfile}" 2>/dev/null || rm -f "${keyfile}"
    fi
    ui_msg "Local mesh (from scratch) — ${sub} (rc=${rc})" "${out:-(no output)}"
}

# _local_mesh_run SUB AUTHKEY NODE_NAME LOGIN_SERVER — one child invocation of the
# shared entrypoint. The auth key (when set) goes into a chmod-600 mktemp file so it
# never appears on the child's argv / process table, and is shredded afterwards.
_local_mesh_run() {
    local sub="$1" authkey="$2" node_name="$3" login_server="$4"
    local -a args=("${sub}")
    local keyfile=""
    if [ -n "${authkey}" ]; then
        keyfile="$(mktemp "${STATE_DIR}/authkey.XXXXXX")" || { ui_msg "Local Docker mesh" "could not create a temp file for the auth key"; return 0; }
        chmod 600 "${keyfile}" 2>/dev/null || true
        printf '%s' "${authkey}" >"${keyfile}"
        args+=(--authkey-file "${keyfile}")
    fi
    [ -n "${node_name}" ]    && args+=(--node-name "${node_name}")
    [ -n "${login_server}" ] && args+=(--login-server "${login_server}")
    args+=(--generator-dir "${REPO_DIR}")
    local out
    out="$(PYTHONPATH="${REPO_DIR}/studio" python3 -m snapdragon_studio.core.local_mesh "${args[@]}" 2>&1)"
    local rc=$?
    if [ -n "${keyfile}" ]; then
        command -v shred >/dev/null 2>&1 && shred -u "${keyfile}" 2>/dev/null || rm -f "${keyfile}"
    fi
    ui_msg "Local Docker mesh — ${sub} (rc=${rc})" "${out:-(no output)}"
}

build_screen() {
    local choice
    choice="$(ui_menu "Build" "What do you want to build?  (path=${OPT_PATH}, ENV=${OPT_ENV}, -j${OPT_JOBS})" \
        all  "Default fleet — 3 Pi + 4 x86 roles" \
        everything "★ FULL matrix — 3 Pi + 12 x86 + Frite + Jetson + Orange Pi 5 + Orange Pi Zero 2 (build-everything)" \
        rpi  "All 3 Raspberry Pi roles" \
        x86  "All 4 default x86 roles" \
        one  "A single arch + role …" \
        omni "x86 omnibus (all-in-one node)" \
        frite "Frite light-desktop image …" \
        back "‹ back to main menu")" || return 0
    case "${choice}" in
        all)   build_make_cmd build-all "default fleet (3 Pi + 4 x86)" 7; launch_build ;;
        everything) build_make_cmd build-everything "full documented matrix (3 Pi + 12 x86 + Frite + Jetson + Orange Pi 5 + Orange Pi Zero 2)" 20; launch_build ;;
        rpi)   build_make_cmd rpi "all 3 Pi roles (${OPT_RPI_BOARD})" 3; launch_build ;;
        x86)   build_make_cmd x86 "all 4 x86 roles" 4; launch_build ;;
        one)   single_role_screen ;;
        omni)  build_make_cmd omnibus "x86 omnibus" 1; launch_build ;;
        frite) frite_screen ;;
        back|"") return 0 ;;
    esac
}

frite_screen() {
    local board flavor desk
    board="$(ui_menu "Frite board" "Frite board variant (current: ${OPT_FRITE_BOARD}):" \
        la-frite "la-frite     — S805X (no microSD)" \
        le-potato "le-potato    — S905X (has SD)" \
        sweet-potato "sweet-potato — S905X-CC-V2 (has SD)" \
        back "‹ back")" || return 0
    [ "${board}" = back ] && return 0
    OPT_FRITE_BOARD="${board}"
    flavor="$(ui_menu "Frite flavor" "Image flavor:" \
        both "both       — live + installer" \
        live "live       — ephemeral USB/SD boot" \
        installer "installer  — writes to eMMC/SD" \
        back "‹ back")" || return 0
    [ "${flavor}" = back ] && return 0
    OPT_FRITE_FLAVOR="${flavor}"
    desk="$(ui_menu "Frite desktop" "Desktop set (--desktop; current: ${OPT_FRITE_DESKTOP}):" \
        light "light — the LEAN LXDE desktop set (DEFAULT)" \
        none "none  — headless base (no desktop at all)" \
        back "‹ back")" || return 0
    [ "${desk}" = back ] && return 0
    OPT_FRITE_DESKTOP="${desk}"
    arm_secrets_prompt "Frite ${board}"
    save_conf
    build_make_cmd frite "Frite ${board} (${flavor}, desktop=${OPT_FRITE_DESKTOP})" 1
    launch_build
}

artifacts_screen() {
    local imgs isos keys body
    imgs="$(ls -1sh "${OPT_WORK_DIR}"/*.img "${OPT_WORK_DIR}"/*.img.xz 2>/dev/null || true)"
    isos="$(ls -1sh "${OPT_WORK_DIR}"/*.iso 2>/dev/null || true)"
    keys="$(ls -1d  "${OPT_WORK_DIR}"/keys-* 2>/dev/null || true)"
    body="Work dir: ${OPT_WORK_DIR}

── images (.img) ──
${imgs:-  (none yet)}

── ISOs (.iso) ──
${isos:-  (none yet)}

── keys folders ──
${keys:-  (none yet)}"
    ui_msg "Artifacts" "${body}"
}

logs_screen() {
    local log; log="$(active_log)"
    if [ -z "${log}" ] || [ ! -f "${log}" ]; then
        ui_msg "Logs" "No build log found yet (looked at ${OPT_WORK_DIR}/build.log and ~/snap-build.log)."
        return 0
    fi
    ui_msg "Log tail — $(basename "${log}")" "$(tail -n 200 "${log}" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g')"
}

clean_screen() {
    ui_yesno "Clean" "Wipe the work dir?\n\n  ${OPT_WORK_DIR}\n\nThis deletes ALL build artifacts + sysroots and forces a from-scratch rebuild." || return 0
    say "running: make clean WORK_DIR=${OPT_WORK_DIR}"
    ( cd "${REPO_DIR}" && make clean "WORK_DIR=${OPT_WORK_DIR}" $([ "${OPT_PATH}" = native ] && echo NATIVE=1) ) \
        && ui_msg "Clean" "Work dir wiped." \
        || ui_msg "Clean" "Clean failed (see terminal output / permissions)."
}

# ── Enterprise phone (Pixel/GrapheneOS) — flashes a HANDSET, builds NO image ────
# A THIN face over scripts/phone-wizard.sh, the driver that owns ALL the logic
# (device-catalog fail-closed gate, sshsig verification, typed-serial flash gate,
# vault-seed escrow custody) — the menu never reimplements or bypasses any of it,
# and never passes --yes/--force. Every setting here is FUNCTION-LOCAL: nothing
# is persisted to menu.conf (save_conf is untouched — a phone serial or auth key
# has no business in a saved conf). The auth key is entered masked (ui_password),
# handed over via a chmod-600 mktemp file (--authkey-file) and shredded after the
# run — the same non-persisted custody as the SA_*/ARM_* secrets and
# _local_mesh_run's TS_AUTHKEY. Runs are FOREGROUND on purpose (no launch_build/
# setsid): the driver is interactive (typed-serial confirm, operator runbooks on
# stdout), so detaching it would orphan its prompts.
phone_screen() {
    local wiz="${SNAP_PHONE_WIZARD:-${SCRIPT_DIR}/phone-wizard.sh}"
    if [ ! -x "${wiz}" ]; then
        ui_msg "Enterprise phone" "driver not found/executable: ${wiz}\n\nThis checkout has no enterprise-phone wizard (see docs/ENTERPRISE-PHONES.md)."
        return 0
    fi
    local codename="" channel="stable" serial="" keys_dir="" login_server="" authkey="" role="" choice
    while :; do
        local keyl
        keyl="$([ -n "${authkey}" ] && echo '(set)' || echo '(unset — enroll then expects your own custody)')"
        choice="$(ui_menu "Enterprise phone" \
            "Flash a USB-connected Google Pixel with VERIFIED GrapheneOS and enroll it in the mesh — no image build. Dry-run by default; every destructive step is gated by the driver itself. Masked auth key; never saved to ${CONF_FILE}." \
            device  "Device codename ...... ${codename:-<detect at run>}" \
            channel "Release channel ...... ${channel}" \
            serial  "Serial ............... ${serial:-<auto when exactly 1 device>}" \
            keys    "Keys dir ............. ${keys_dir:-<none — use server/auth key below>}" \
            server  "Login server ......... ${login_server:-<from keys-dir>}" \
            authkey "Auth key ............. ${keyl}" \
            role    "Mesh role ............ ${role:-<driver default: user>}" \
            wizard  "★ Guided wizard (detect → fetch → flash → enroll → profile → ingest)" \
            plan    "Preview the plan (dry-run — touches NOTHING)" \
            detect  "Detect the connected device (read-only)" \
            fetch   "Fetch + VERIFY GrapheneOS" \
            flash   "FLASH the device (DESTRUCTIVE — typed-serial gate)" \
            enroll  "Enroll in the mesh (tailnet join)" \
            profile "Create + escrow the enterprise profile" \
            ingest  "Emit the device-registry ingest record" \
            status  "Status (read-only)" \
            back    "‹ back")" || return 0
        case "${choice}" in
            device)
                # Picker fed LIVE from the driver's own vetted catalog (the driver
                # FAILS CLOSED, exit 4, on any codename not in it — no bypass here).
                local tsv devs=() cn nm
                tsv="$(dirname "${wiz}")/phone-devices.tsv"
                if [ -f "${tsv}" ]; then
                    while IFS=$'\t' read -r cn nm; do
                        case "${cn}" in ''|'#'*) continue ;; esac
                        devs+=("${cn}" "${nm} (${cn})")
                    done <"${tsv}"
                fi
                if [ "${#devs[@]}" -eq 0 ]; then
                    codename="$(ui_input "Device codename" "GrapheneOS device codename (blank = detect at run)" "${codename}")"
                else
                    cn="$(ui_menu "Device" "The vetted GrapheneOS device catalog ($(basename "${tsv}"))." \
                        detect "<detect at run — probe the connected device>" "${devs[@]}")" || cn=""
                    case "${cn}" in detect) codename="" ;; "") : ;; *) codename="${cn}" ;; esac
                fi ;;
            channel) channel="$(ui_menu "Channel" "GrapheneOS release channel (stable is the vetted default)" \
                        stable "stable — production releases" \
                        beta   "beta  — preview" \
                        alpha  "alpha — earliest")" || channel="stable"; [ -n "${channel}" ] || channel="stable" ;;
            serial)  serial="$(ui_input "Serial" "Target device serial (blank = auto when exactly one device is connected)" "${serial}")" ;;
            keys)    keys_dir="$(ui_input "Keys dir" "Keys dir, docker-mesh-node layout: login-server, tailscale/authkey, role (blank = use the server/auth-key fields)" "${keys_dir}")" ;;
            server)  login_server="$(ui_input "Login server" "Headscale control URL (blank = the keys-dir login-server file)" "${login_server}")" ;;
            authkey) authkey="$(ui_password "Auth key" "One-time tailnet/headscale pre-auth key (blank = unset; the enroll runbook then expects it from your own custody)")" ;;
            role)    role="$(ui_menu "Mesh role" "Mesh role for the enrollment record" \
                        default    "<driver default — user, or the keys-dir role file>" \
                        user       "user" \
                        mod        "mod" \
                        admin      "admin" \
                        superadmin "superadmin")" || role=""
                     [ "${role}" = default ] && role="" ;;
            wizard|plan|detect|fetch|flash|enroll|profile|ingest|status)
                _phone_run "${choice}" "${authkey}" "${codename}" "${channel}" "${serial}" "${keys_dir}" "${login_server}" "${role}" ;;
            back|"") return 0 ;;
        esac
    done
}

# _phone_run VERB AUTHKEY CODENAME CHANNEL SERIAL KEYS_DIR LOGIN_SERVER ROLE — one
# FOREGROUND child invocation of the enterprise-phone driver, terminal fully
# attached (stdin for its typed-serial/wizard prompts, stdout for its runbooks).
# The auth key (when set) goes into a chmod-600 mktemp file (off the argv / process
# table) and is shredded afterwards — _local_mesh_bootstrap_run's exact pattern.
_phone_run() {
    local verb="$1" authkey="$2" codename="$3" channel="$4" serial="$5" keys_dir="$6" login_server="$7" role="$8"
    local wiz="${SNAP_PHONE_WIZARD:-${SCRIPT_DIR}/phone-wizard.sh}"
    local -a args=("${verb}")
    [ -n "${codename}" ]     && args+=(--codename "${codename}")
    [ -n "${channel}" ]      && args+=(--channel "${channel}")
    [ -n "${serial}" ]       && args+=(--serial "${serial}")
    [ -n "${keys_dir}" ]     && args+=(--keys-dir "${keys_dir}")
    [ -n "${login_server}" ] && args+=(--login-server "${login_server}")
    [ -n "${role}" ]         && args+=(--role "${role}")
    local keyfile=""
    if [ -n "${authkey}" ]; then
        keyfile="$(mktemp "${STATE_DIR}/phonekey.XXXXXX")" || { ui_msg "Enterprise phone" "could not create a temp file for the auth key"; return 0; }
        chmod 600 "${keyfile}" 2>/dev/null || true
        printf '%s' "${authkey}" >"${keyfile}"
        args+=(--authkey-file "${keyfile}")
    fi
    say "running: scripts/phone-wizard.sh ${verb} (foreground — output follows)"
    "${wiz}" "${args[@]}"
    local rc=$?
    if [ -n "${keyfile}" ]; then
        command -v shred >/dev/null 2>&1 && shred -u "${keyfile}" 2>/dev/null || rm -f "${keyfile}"
    fi
    if [ "${rc}" -eq 0 ]; then say "phone-wizard ${verb}: OK"; else warn "phone-wizard ${verb}: exit ${rc}"; fi
    # Pause so the driver's output survives the next menu redraw — but only when a
    # human is actually attached (tests call this with stdin redirected).
    if [ -t 0 ]; then read -r -p "press Enter to return to the menu… " _ </dev/tty || true; fi
    return 0
}

main_menu() {
    while true; do
        local running="" def="all"
        if menu_build_alive; then running="OURS (PID $(menu_build_pid))";
        elif [ -n "$(foreign_build_pid)" ]; then running="detected (PID $(foreign_build_pid))"; fi
        [ -n "${running}" ] && def="monitor"

        local status_line="path=${OPT_PATH}  env=${OPT_ENV}  -j${OPT_JOBS}"
        [ -n "${running}" ] && status_line="${status_line}   ${C_GRN}● build running: ${running}${C_RST}"

        local -a items=()
        [ -n "${running}" ] && items+=(monitor "▶ Monitor the running build (live progress)")
        items+=(
            build   "Build images …"
            options "Options (path / env / brand / jobs) …"
            artifacts "Show built artifacts"
            logs    "Show build log tail"
            clean   "Clean / wipe work dir"
            quit    "Quit  (any running build keeps going)"
        )
        local choice
        choice="$(ui_menu "Main" "${status_line}" "${items[@]}")" || { confirm_quit && return 0 || continue; }
        case "${choice}" in
            monitor)   monitor_build ;;
            build)     mode_screen ;;
            options)   options_screen ;;
            artifacts) artifacts_screen ;;
            logs)      logs_screen ;;
            clean)     clean_screen ;;
            quit|"")   confirm_quit && return 0 ;;
        esac
    done
}

confirm_quit() {
    if menu_build_alive || [ -n "$(foreign_build_pid)" ]; then
        ui_yesno "Quit" "A build is still running. Quit the menu and LEAVE it running?\n\n(Re-run this menu any time to come back to its live progress.)" || return 1
        say "leaving build running — relaunch this menu to re-attach."
    fi
    return 0
}

# ── Entry point ─────────────────────────────────────────────────────────────────
main() {
    [ -f "${REPO_DIR}/Makefile" ] || die "must run inside the snapdragon-generator repo (no Makefile at ${REPO_DIR})"
    if [ "${HAVE_TUI}" != 1 ]; then
        warn "whiptail/TTY not available — using the plain text menu (set NO_TUI= to re-enable; install dev-libs/newt for the rich UI)."
    fi
    # If a build is already running (ours OR launched by hand), open its monitor
    # first so 'bring it up again with current progress' is the default landing.
    if menu_build_alive || [ -n "$(foreign_build_pid)" ]; then
        say "a build is already running — opening its live monitor (press q for the menu)."
        monitor_build
    fi
    main_menu
    clear 2>/dev/null || true
}

# Run only when executed directly; `source`-ing the file (e.g. for tests) just
# loads the functions without starting the interactive menu.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi

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
OPT_PENTEST="no"          # yes => run the OWASP pen-test after the build (PENTEST=1)
OPT_IMGFLAGS=""           # e.g. --no-iso (img only) / --no-img (iso only)
# ── Edge-AI inference service (GPU cluster roles: be+gpu / omnibus / edge_ai) ───
OPT_X86_EDGE_AI="no"          # yes => add the edge-ai service to be+gpu/omnibus (edge_ai role always has it)
OPT_EDGE_AI_RUNTIME="ollama"  # edge-ai inference runtime (ollama | vllm)
OPT_EDGE_AI_MODELS=""         # comma list of models to PRELOAD (empty = builder default)
OPT_EDGE_AI_MODEL_DEFAULT=""  # default model when an OpenAI request omits one (empty = builder default)
OPT_X86_EDGE_AI_ANALYSIS="no" # yes => also bake the edge-ai-analysis task API (image/log verdicts; separate image)
# ── Tor v3 onion (hidden) service — node-scoped optional, DEFAULT-OFF ──────────
OPT_TOR_ONION="no"            # yes => --with-tor: expose the in-cluster fe-gateway as a v3 .onion
OPT_FRITE_BOARD="la-frite"
OPT_FRITE_FLAVOR="both"
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
# SECRETS are deliberately NOT persisted (never written to ${CONF_FILE}); they are
# prompted fresh each build and live only in these shell vars for the run.
SA_LOCAL_PASS=""              # local user password (plaintext, hashed by the builder)
SA_LUKS_PASS=""               # LUKS root-unlock passphrase (build-time only)
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
        printf 'OPT_PENTEST=%q\n'       "${OPT_PENTEST}"
        printf 'OPT_IMGFLAGS=%q\n'      "${OPT_IMGFLAGS}"
        printf 'OPT_X86_EDGE_AI=%q\n'   "${OPT_X86_EDGE_AI}"
        printf 'OPT_EDGE_AI_RUNTIME=%q\n' "${OPT_EDGE_AI_RUNTIME}"
        printf 'OPT_EDGE_AI_MODELS=%q\n'  "${OPT_EDGE_AI_MODELS}"
        printf 'OPT_EDGE_AI_MODEL_DEFAULT=%q\n' "${OPT_EDGE_AI_MODEL_DEFAULT}"
        printf 'OPT_X86_EDGE_AI_ANALYSIS=%q\n' "${OPT_X86_EDGE_AI_ANALYSIS}"
        printf 'OPT_TOR_ONION=%q\n'     "${OPT_TOR_ONION}"
        printf 'OPT_FRITE_BOARD=%q\n'   "${OPT_FRITE_BOARD}"
        printf 'OPT_FRITE_FLAVOR=%q\n'  "${OPT_FRITE_FLAVOR}"
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
    p="$(pgrep -f 'build-all-roles\.sh|build-(rpi5|x86-host|frite)-stage4\.sh' 2>/dev/null | head -n1)"
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

# ── Compose the make command for a given selection ──────────────────────────────
# Returns (via globals) the env-var prefix + the make argument list. Everything
# the menu can tweak is mapped onto the existing Makefile knobs — no new engine.
RUN_DESC=""; RUN_ROLES_TOTAL=1; declare -a RUN_MAKE=()
build_make_cmd() {
    local target="$1" desc="$2" roles_total="$3"
    RUN_DESC="${desc}"; RUN_ROLES_TOTAL="${roles_total}"
    RUN_MAKE=("${target}")
    # Make-vars are passed as args (they override ?= defaults cleanly).
    RUN_MAKE+=("WORK_DIR=${OPT_WORK_DIR}" "JOBS=${OPT_JOBS}" "ENV=${OPT_ENV}")
    [ -n "${OPT_BRAND}" ]  && RUN_MAKE+=("BRAND=${OPT_BRAND}")
    [ -n "${OPT_DOMAIN}" ] && RUN_MAKE+=("DOMAIN=${OPT_DOMAIN}")
    [ -n "${OPT_IMGFLAGS}" ] && RUN_MAKE+=("IMG_FLAGS=${OPT_IMGFLAGS}")
    # Root SSH login: only forwarded when opted IN; empty => every image stays hardened
    # (PermitRootLogin no) by the builders' own default. Applies to ALL targets/arches.
    [ -n "${OPT_ROOT_LOGIN}" ] && [ "${OPT_ROOT_LOGIN}" != "no" ] && RUN_MAKE+=("PERMIT_ROOT_LOGIN=${OPT_ROOT_LOGIN}")
    [ "${OPT_PATH}" = native ] && RUN_MAKE+=("NATIVE=1")
    # RESUME, X86_OMNIBUS and PENTEST are read ONLY by scripts/build-all-roles.sh,
    # which the Makefile invokes solely from the full-fleet (build-all) target. The
    # per-arch / single-role targets ignore them — and a single-role build WITHOUT
    # --resume deliberately WIPES its sysroot. So emitting them for those targets is
    # at best a silent no-op and at worst a destructive surprise. Gate them to the
    # fleet build (the Options screen tells the user they apply there).
    if [ "${target}" = build-all ]; then
        [ "${OPT_RESUME}" = yes ]  && RUN_MAKE+=("RESUME=--resume")
        [ "${OPT_OMNIBUS}" = yes ] && RUN_MAKE+=("X86_OMNIBUS=1")
        [ "${OPT_PENTEST}" = yes ] && RUN_MAKE+=("PENTEST=1")
    fi
    # Frite board/flavor only matter for the frite target but are harmless else.
    if [ "${target}" = frite ]; then
        RUN_MAKE+=("FRITE_BOARD=${OPT_FRITE_BOARD}" "FRITE_FLAVOR=${OPT_FRITE_FLAVOR}")
    fi
    # Standalone hardened NVIDIA desktop: thread the collected options as builder
    # flags via STANDALONE_FLAGS (consumed by the Makefile x86-standalone* targets).
    # NOTE: --local-pass lands in the process argv (visible to `ps` on this box);
    # acceptable on a single-user build host. The builder hashes it immediately and
    # never bakes the plaintext. The LUKS root passphrase is NOT passed here unless
    # the user opts into an unattended one — the installer prompts at install time.
    if [[ "${target}" == x86-standalone* ]]; then
        local sf=""
        sf+=" --gpu-driver ${OPT_SA_GPU}"
        sf+=" --steam ${OPT_SA_STEAM}"
        [ "${OPT_SA_MEDIA}" = no ] && sf+=" --no-media-data"
        [ -n "${OPT_SA_USER}" ] && sf+=" --local-user ${OPT_SA_USER}"
        [ -n "${SA_LOCAL_PASS}" ] && sf+=" --local-pass ${SA_LOCAL_PASS}"
        [ -n "${SA_LUKS_PASS}" ]  && sf+=" --luks-pass ${SA_LUKS_PASS}"
        [ "${OPT_SA_KEYFILE}" != none ] && sf+=" --unlock-keyfile ${OPT_SA_KEYFILE}"
        [ "${OPT_SA_YUBIKEY}" != none ] && sf+=" --unlock-yubikey ${OPT_SA_YUBIKEY}"
        # branding + security stack + monolithic kernel + egress VPN
        { [ -n "${OPT_SA_THEME}" ] && [ "${OPT_SA_THEME}" != none ]; } && sf+=" --theme ${OPT_SA_THEME}"
        [ "${OPT_SA_PROXY}" = no ]    && sf+=" --no-proxy-stack"
        [ "${OPT_SA_SNORT}" = no ]    && sf+=" --no-snort"
        [ "${OPT_SA_AIDE}" = yes ]    && sf+=" --with-aide"
        [ "${OPT_SA_KBUILTIN}" = yes ] && sf+=" --kernel-builtin"
        [ -n "${OPT_SA_EGRESS}" ]     && sf+=" --egress-vpn ${OPT_SA_EGRESS}"
        RUN_MAKE+=("STANDALONE_FLAGS=${sf# }")
    fi
    # Edge-AI inference service on a GPU cluster role. The edge_ai role ALWAYS bakes
    # it (auto-selected by the builder); be+gpu/omnibus add it only when OPT_X86_EDGE_AI=yes.
    # Threaded via STANDALONE_FLAGS, which the Makefile x86-% pattern appends to --role.
    case "${target}" in
        x86-be+gpu|x86-omnibus|x86-edge_ai)
            local ef=""
            [ "${target}" != x86-edge_ai ] && [ "${OPT_X86_EDGE_AI}" = yes ] && ef+=" --with-edge-ai"
            if [ "${target}" = x86-edge_ai ] || [ "${OPT_X86_EDGE_AI}" = yes ]; then
                [ -n "${OPT_EDGE_AI_RUNTIME}" ] && [ "${OPT_EDGE_AI_RUNTIME}" != ollama ] && ef+=" --edge-ai-runtime ${OPT_EDGE_AI_RUNTIME}"
                [ -n "${OPT_EDGE_AI_MODELS}" ]  && ef+=" --edge-ai-models ${OPT_EDGE_AI_MODELS}"
                [ -n "${OPT_EDGE_AI_MODEL_DEFAULT}" ] && ef+=" --edge-ai-model-default ${OPT_EDGE_AI_MODEL_DEFAULT}"
            fi
            # --with-edge-ai-analysis folds edge-ai too (its dependency), so it applies on
            # any GPU target incl. the edge_ai role.
            [ "${OPT_X86_EDGE_AI_ANALYSIS}" = yes ] && ef+=" --with-edge-ai-analysis"
            # Tor v3 onion service folds into the SAME STANDALONE_FLAGS emit on GPU roles
            # (never a second STANDALONE_FLAGS= for one make invocation).
            [ "${OPT_TOR_ONION}" = yes ] && ef+=" --with-tor"
            [ -n "${ef}" ] && RUN_MAKE+=("STANDALONE_FLAGS=${ef# }")
            ;;
    esac
    # Tor v3 onion service applies to ANY x86 CLUSTER role (not standalone desktops,
    # which are not cluster members). On the GPU targets it is folded into ef above; for
    # the REMAINING x86 cluster roles emit it as their STANDALONE_FLAGS here so the
    # Makefile x86-% pattern threads --with-tor onto --role. The cases are DISJOINT, so a
    # single make invocation never gets a double STANDALONE_FLAGS= (the no-op desktop
    # builder guard on !ROLE_CLIENT makes an accidental --with-tor harmless anyway).
    case "${target}" in
        x86-standalone*|x86-be+gpu|x86-omnibus|x86-edge_ai) ;;   # handled above (or N/A)
        x86-*) [ "${OPT_TOR_ONION}" = yes ] && RUN_MAKE+=("STANDALONE_FLAGS=--with-tor") ;;
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
    local _shown="${RUN_MAKE[*]}"
    _shown="$(printf '%s' "${_shown}" | sed -E 's/(--local-pass|--luks-pass)[[:space:]]+[^[:space:]]+/\1 ****/g')"
    say "launching: ${launch[*]:-} make ${_shown}"
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
    rline="$(grep -aE '(#  Building (RPi5|x86|Frite)|^==> (Pi|x86|Frite) |Building .* role:)' "${log}" 2>/dev/null | tail -n1)"
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
    roles_seen="$(grep -acE '(#  Building (RPi5|x86|Frite)|^==> (Pi|x86|Frite) )' "${log}" 2>/dev/null)"
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
# Studio wizard + the --edge-ai-* CLI flags expose (all-menus parity).
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
            back    "‹ back")" || return 0
        case "${c}" in
            toggle)  OPT_X86_EDGE_AI="$([ "${OPT_X86_EDGE_AI}" = yes ] && echo no || echo yes)" ;;
            analysis) OPT_X86_EDGE_AI_ANALYSIS="$([ "${OPT_X86_EDGE_AI_ANALYSIS}" = yes ] && echo no || echo yes)" ;;
            runtime) OPT_EDGE_AI_RUNTIME="$([ "${OPT_EDGE_AI_RUNTIME}" = ollama ] && echo vllm || echo ollama)" ;;
            models)  OPT_EDGE_AI_MODELS="$(ui_input "Preload models" "Comma list of model tags to preload (e.g. llama3.2:3b,nomic-embed-text; empty = builder default)" "${OPT_EDGE_AI_MODELS}")" ;;
            default) OPT_EDGE_AI_MODEL_DEFAULT="$(ui_input "Default model" "Model returned when a request omits one (empty = builder default)" "${OPT_EDGE_AI_MODEL_DEFAULT}")" ;;
            back|"") save_conf; return 0 ;;
        esac
        save_conf
    done
}

options_screen() {
    while true; do
        local resume_l omni_l pen_l
        resume_l="$([ "${OPT_RESUME}" = yes ] && echo on || echo off)"
        omni_l="$([ "${OPT_OMNIBUS}" = yes ] && echo on || echo off)"
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
            pentest  "OWASP pen-test ...... ${pen_l}   (full-fleet build only)" \
            edgeai   "Edge-AI service ..... $([ "${OPT_X86_EDGE_AI}" = yes ] && echo on || echo off)   (be+gpu/omnibus; edge_ai role always on)" \
            tor      "Tor v3 onion ........ $([ "${OPT_TOR_ONION}" = yes ] && echo on || echo off)   (node service; exposes fe-gateway as .onion; default off)" \
            imgflags "Image format flags .. ${OPT_IMGFLAGS:-<both .img + .iso>}" \
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
            pentest) OPT_PENTEST="$([ "${OPT_PENTEST}" = yes ] && echo no || echo yes)" ;;
            edgeai)  edge_ai_options_screen ;;
            tor)     OPT_TOR_ONION="$([ "${OPT_TOR_ONION}" = yes ] && echo no || echo yes)" ;;
            imgflags) OPT_IMGFLAGS="$(ui_input "Image flags" "IMG_FLAGS (e.g. --no-iso, --no-img, empty = both)" "${OPT_IMGFLAGS}")" ;;
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
    local arch role
    arch="$(ui_menu "Single role" "Which architecture?" \
        rpi "Raspberry Pi 5 (arm64 cluster node)" \
        x86 "x86-64 (amd64 node / GPU host / client)" \
        back "‹ back")" || return 0
    case "${arch}" in
        rpi)
            role="$(ui_menu "Pi role" "Pick a Raspberry Pi role:" \
                pki "pki      — cluster PKI / control" \
                backend "backend  — backend services node" \
                frontend "frontend — gateway / UI node" \
                back "‹ back")" || return 0
            [ "${role}" = back ] && return 0
            build_make_cmd "rpi-${role}" "Pi ${role} (${OPT_PATH}, ENV=${OPT_ENV})" 1
            launch_build ;;
        x86)
            role="$(ui_menu "x86 role" "Pick an x86 role:" \
                pki "pki     — cluster PKI / control" \
                be "be      — backend node" \
                fe "fe      — frontend / gateway node" \
                be+gpu "be+gpu  — backend + GPU host (the e2e GPU node)" \
                omnibus "omnibus — all-in-one single node" \
                edge_ai "edge_ai — GPU inference node (OpenAI model API to the mesh)" \
                laptop "laptop  — amd64 client image" \
                chromebook "chromebook — thin client image" \
                desktop "desktop — full desktop client image" \
                standalone-thin "★ standalone-thin — hardened NVIDIA desktop (LXDE; no mesh/SSO)" \
                standalone-thick "★ standalone-thick — most-capable Plasma NVIDIA desktop (no mesh/SSO)" \
                back "‹ back")" || return 0
            [ "${role}" = back ] && return 0
            case "${role}" in
                standalone-thin|standalone-thick) standalone_screen "${role}" ;;
                *) build_make_cmd "x86-${role}" "x86 ${role} (${OPT_PATH}, ENV=${OPT_ENV})" 1
                   launch_build ;;
            esac ;;
        *) return 0 ;;
    esac
}

# Standalone hardened NVIDIA desktop: collect the local user + password, NVIDIA
# driver, Steam, media-data and optional unlock factor, then launch. Passwords are
# prompted fresh (never persisted); the LUKS root passphrase is set at INSTALL time.
standalone_screen() {
    local role="$1" choice weight
    weight="thin"; [ "${role}" = standalone-thick ] && weight="full (most-capable Plasma)"
    while :; do
        local media_l
        media_l="$([ "${OPT_SA_MEDIA}" = yes ] && echo "ON (/media Vaults+Steam auto-detect)" || echo OFF)"
        choice="$(ui_menu "Standalone ${weight}" \
            "Hardened NVIDIA standalone desktop — no mesh, no SSO, local login. Installed system is LUKS2-encrypted (you set the root passphrase at install)." \
            user    "Local user ......... ${OPT_SA_USER}" \
            pass    "Local password ..... $([ -n "${SA_LOCAL_PASS}" ] && echo '(set)' || echo '(unset → random at first boot)')" \
            gpu     "GPU driver ......... ${OPT_SA_GPU}" \
            steam   "Steam delivery ..... ${OPT_SA_STEAM}  (library on /media/Steam)" \
            media   "Media data ......... ${media_l}" \
            keyfile "Keyfile unlock ..... ${OPT_SA_KEYFILE}   (boot=LUKS keyslot / login=PAM)" \
            yubikey "YubiKey unlock ..... ${OPT_SA_YUBIKEY}   (boot=FIDO2 / login=pam_u2f)" \
            theme   "Branding theme ..... ${OPT_SA_THEME}" \
            security "Security stack .... proxy=${OPT_SA_PROXY} snort=${OPT_SA_SNORT} aide=${OPT_SA_AIDE}" \
            kernel  "Kernel built-in .... ${OPT_SA_KBUILTIN}   (=y vs modules)" \
            egress  "Egress VPN ......... ${OPT_SA_EGRESS:-<none>}" \
            luks    "Unattended LUKS pass $([ -n "${SA_LUKS_PASS}" ] && echo '(set — advanced)' || echo '(installer prompts — recommended)')" \
            build   "★ BUILD this image (live ISO + stage4 + .fs.tar.xz + installer ISO)" \
            back    "‹ back")" || return 0
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
                     build_make_cmd "x86-${role}" "x86 ${role} hardened NVIDIA standalone (${OPT_PATH}, ENV=${OPT_ENV})" 1
                     launch_build; return 0 ;;
            back|"") save_conf; return 0 ;;
        esac
        save_conf
    done
}

build_screen() {
    local choice
    choice="$(ui_menu "Build" "What do you want to build?  (path=${OPT_PATH}, ENV=${OPT_ENV}, -j${OPT_JOBS})" \
        all  "Default fleet — 3 Pi + 4 x86 roles" \
        rpi  "All 3 Raspberry Pi roles" \
        x86  "All 4 default x86 roles" \
        one  "A single arch + role …" \
        omni "x86 omnibus (all-in-one node)" \
        frite "Frite light-desktop image …" \
        back "‹ back to main menu")" || return 0
    case "${choice}" in
        all)   build_make_cmd build-all "default fleet (3 Pi + 4 x86)" 7; launch_build ;;
        rpi)   build_make_cmd rpi "all 3 Pi roles" 3; launch_build ;;
        x86)   build_make_cmd x86 "all 4 x86 roles" 4; launch_build ;;
        one)   single_role_screen ;;
        omni)  build_make_cmd omnibus "x86 omnibus" 1; launch_build ;;
        frite) frite_screen ;;
        back|"") return 0 ;;
    esac
}

frite_screen() {
    local board flavor
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
    save_conf
    build_make_cmd frite "Frite ${board} (${flavor})" 1
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
            build)     build_screen ;;
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

#!/usr/bin/env bash
# studio-launch.sh — HugMesh Image Studio launcher + guided Linux bootstrap for
# NixOS / SteamOS (Steam Deck) / Arch / Debian·Ubuntu / Fedora and other non-FHS or
# no-`make` hosts. The POSIX sibling of studio/hugmesh-studio.bat.
#
# On a ready box it launches the wizard straight away. On a bare box it DETECTS what is
# missing (a Python 3.10+, PySide6/PyQt6, a venv, make, whiptail, nix), reports each fact
# on one machine-greppable DETECT line, and OFFERS a consent-gated project-local venv. It
# NEVER installs anything without an explicit y/N answer (or --auto), it NEVER calls the
# system package manager (apt/dnf/pacman) itself — it only prints the exact command for you
# to run — and it never downloads-and-executes a remote script.
#
#   scripts/studio-launch.sh            guided run (detect, offer a venv, launch the wizard)
#   scripts/studio-launch.sh --detect   print the DETECT report and exit (never prompts)
#   scripts/studio-launch.sh --auto      as guided, but every offer is accepted
#   scripts/studio-launch.sh --menu      hand off to the ncurses build menu (build-menu.sh)
#   scripts/studio-launch.sh --redo-first-run
#                                        force the first-run bootstrap (symlinks/properties/
#                                        doctor — scripts/_first-run-lib.sh, issue #49)
#   scripts/studio-launch.sh --...       any OTHER --arg is HEADLESS automation: no prompts,
#                                        no installs, straight to `python3 -m hugmesh_studio`
#                                        (e.g. --print-command, the build-matrix GUI channel)
#
# Unlike the older studio/hugmesh-studio one-liner (which only worked when the CWD was
# studio/), this exports PYTHONPATH=$REPO/studio so the wizard launches from ANY directory —
# the canonical invocation the Makefile uses (PYTHONPATH=studio python3 -m hugmesh_studio).
#
# Exit codes: 0 launched (or --detect done), 1 launch/probe failure or no Python on a host we
# cannot bootstrap, 2 a required step was declined.
#
# Interactive, so — like scripts/build-menu.sh — it deliberately does NOT use `set -e`: it
# runs many commands that fail benignly (a missing binary, a declined prompt). We keep -u and
# handle every error explicitly.
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
STUDIO_DIR="${REPO_DIR}/studio"
# The bootstrap venv lives INSIDE the (writable) checkout — same path the Windows .bat uses
# (studio/.venv-studio) — so on a read-only rootfs (SteamOS) nothing outside $HOME is touched.
VENV_DIR="${STUDIO_DIR}/.venv-studio"
VENV_PY="${VENV_DIR}/bin/python"
# Mirrors studio/hugmesh-studio.bat's PYTHON_MIN=3.10 and studio/README.md.
PYTHON_MIN_MAJOR=3
PYTHON_MIN_MINOR=10

# THE load-bearing fix vs studio/hugmesh-studio:3-4 (which computed `here` but never used
# it): export PYTHONPATH so `python3 -m hugmesh_studio` resolves from any working directory.
export PYTHONPATH="${STUDIO_DIR}${PYTHONPATH:+:${PYTHONPATH}}"

# First-run bootstrap (issue #49): symlinks + properties + advisory doctor. Sourcing only
# defines functions; the call sits in the dispatch below (guided/--menu paths — the headless
# automation channel documents "no installs", and --detect documents "report only").
# Located off BASH_SOURCE, not SCRIPT_DIR: when the TEST SUITE sources this launcher, $0
# (hence SCRIPT_DIR) points at the test dir, but the lib always sits next to THIS file.
# shellcheck source=scripts/_first-run-lib.sh
. "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/_first-run-lib.sh"

# ── Colours (only when stderr is a TTY, matching scripts/build-menu.sh) ──────────
if [ -t 2 ]; then
    C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_RST=$'\033[0m'
else
    C_RED=''; C_YEL=''; C_GRN=''; C_RST=''
fi
say()  { printf '%s[studio-launch]%s %s\n' "${C_GRN}" "${C_RST}" "$*" >&2; }
warn() { printf '%s[studio-launch] WARN:%s %s\n' "${C_YEL}" "${C_RST}" "$*" >&2; }
die()  { printf '%s[studio-launch] ERROR:%s %s\n' "${C_RED}" "${C_RST}" "$*" >&2; exit 1; }

# ── arg scan: runs before ANY probe or prompt (automation must never see one) ────
# --detect/--auto/--menu are launcher-local; ANY OTHER --arg means headless automation.
DETECT_ONLY=0
AUTO=0
WANT_MENU=0
HEADLESS=0
REDO_FIRST_RUN=0
FORWARD=()                 # args passed through to python (or to build-menu.sh for --menu)
for arg in "$@"; do
    case "${arg}" in
        --detect) DETECT_ONLY=1 ;;
        --auto)   AUTO=1 ;;
        --menu)   WANT_MENU=1 ;;
        # Launcher-local (like --detect/--auto): force the first-run bootstrap. NOT
        # forwarded — hugmesh_studio's argparse does not know it.
        --redo-first-run) REDO_FIRST_RUN=1 ;;
        # Interactive GUI modes (app.py opens a window/tray — they NEED Qt + a display):
        # forward them but keep the GUIDED path (distro report + consent-gated venv
        # bootstrap), so on a bare box they get the guided setup instead of a raw
        # PySide6/PyQt6 ImportError. Genuinely-headless flags (--login-agent,
        # --print-command/-commands/-specs, --askpass) fall through to --*) below.
        --tray|--stack-tray|--go-live|--fleet|--dev)
                  FORWARD+=("${arg}") ;;
        --*)      HEADLESS=1; FORWARD+=("${arg}") ;;
        *)        FORWARD+=("${arg}") ;;
    esac
done
# NOTE: FORWARD is expanded as ${FORWARD[@]+"${FORWARD[@]}"} everywhere below — the
# `set -u`-safe form for a possibly-empty array (bash < 4.4 chokes on a bare "${a[@]}").

# ── /etc/os-release (distro id) ──────────────────────────────────────────────────
OS_ID=""
OS_ID_LIKE=""
read_os_release() {
    OS_ID=""; OS_ID_LIKE=""
    [ -r /etc/os-release ] || return 0
    # Read in a subshell so os-release's NAME/VERSION/... never leak into this script.
    OS_ID="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")"
    OS_ID_LIKE="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}")"
}
# match $1 against ID exactly OR a whitespace-separated token of ID_LIKE
id_matches() {
    [ "${OS_ID}" = "$1" ] && return 0
    case " ${OS_ID_LIKE} " in *" $1 "*) return 0 ;; esac
    return 1
}
distro_family() {
    case "${OS_ID}" in
        nixos)                                              echo nixos; return ;;
        steamos|arch|manjaro|endeavouros|garuda|arcolinux)  echo arch;  return ;;
        debian|ubuntu|pop|linuxmint|elementary|zorin|raspbian) echo debian; return ;;
        fedora|rhel|centos|rocky|almalinux|nobara|bazzite)  echo fedora; return ;;
    esac
    if id_matches arch;                       then echo arch;   return; fi
    if id_matches debian || id_matches ubuntu; then echo debian; return; fi
    if id_matches fedora || id_matches rhel;   then echo fedora; return; fi
    echo unknown
}

in_nix_shell() { [ -n "${IN_NIX_SHELL:-}" ]; }
have_nix()     { command -v nix >/dev/null 2>&1; }
# Game Mode runs gamescope (Wayland); Qt wants XWayland (QT_QPA_PLATFORM=xcb) there.
in_gamescope() {
    case "${XDG_CURRENT_DESKTOP:-}" in *[Gg]amescope*) return 0 ;; esac
    [ -n "${GAMESCOPE_WAYLAND_DISPLAY:-}" ]
}

# ── probes (quiet: set variables; run_detect does the reporting) ─────────────────
PY_CMD=""; PY_VERSION=""; PY_PATH=""
probe_python() {
    PY_CMD=""; PY_VERSION=""; PY_PATH=""
    local cand
    # Newest first, then the generic names, so we pick the highest available >= min.
    for cand in python3.13 python3.12 python3.11 python3.10 python3 python; do
        command -v "${cand}" >/dev/null 2>&1 || continue
        "${cand}" -c "import sys; raise SystemExit(0 if sys.version_info >= (${PYTHON_MIN_MAJOR}, ${PYTHON_MIN_MINOR}) else 1)" >/dev/null 2>&1 || continue
        PY_CMD="${cand}"
        PY_VERSION="$("${cand}" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null)"
        PY_PATH="$(command -v "${cand}")"
        return 0
    done
    return 1
}
QT_SCOPE=none; QT_BINDING=none; VENV_OK=0
probe_qt() {
    QT_SCOPE=none; QT_BINDING=none; VENV_OK=0
    if [ -x "${VENV_PY}" ]; then
        VENV_OK=1
        "${VENV_PY}" -c 'import PySide6' >/dev/null 2>&1 && { QT_SCOPE=venv; QT_BINDING=PySide6; return 0; }
        "${VENV_PY}" -c 'import PyQt6'   >/dev/null 2>&1 && { QT_SCOPE=venv; QT_BINDING=PyQt6;   return 0; }
    fi
    [ -n "${PY_CMD}" ] || return 1
    # gui/qt.py accepts either binding: PySide6 preferred, PyQt6 fallback.
    "${PY_CMD}" -c 'import PySide6' >/dev/null 2>&1 && { QT_SCOPE=system; QT_BINDING=PySide6; return 0; }
    "${PY_CMD}" -c 'import PyQt6'   >/dev/null 2>&1 && { QT_SCOPE=system; QT_BINDING=PyQt6;   return 0; }
    return 1
}

# ── the DETECT report: one machine-greppable line per fact (mirrors the .bat) ─────
run_detect() {
    read_os_release
    probe_python || true
    probe_qt || true
    local fam; fam="$(distro_family)"
    printf 'DETECT os=%s id_like=%s family=%s nix_shell=%s gamescope=%s\n' \
        "${OS_ID:-none}" "${OS_ID_LIKE:-none}" "${fam}" \
        "$(in_nix_shell && echo 1 || echo 0)" "$(in_gamescope && echo 1 || echo 0)"
    if [ -n "${PY_CMD}" ]; then
        printf 'DETECT python=found version=%s path=%s\n' "${PY_VERSION}" "${PY_PATH}"
    else
        printf 'DETECT python=missing version=none path=none min=%s.%s\n' "${PYTHON_MIN_MAJOR}" "${PYTHON_MIN_MINOR}"
    fi
    if [ "${QT_SCOPE}" != none ]; then
        printf 'DETECT qt=found binding=%s scope=%s\n' "${QT_BINDING}" "${QT_SCOPE}"
    else
        printf 'DETECT qt=missing binding=none scope=none\n'
    fi
    if [ "${VENV_OK}" = 1 ]; then
        printf 'DETECT venv=found path=%s\n' "${VENV_DIR}"
    else
        printf 'DETECT venv=missing path=%s\n' "${VENV_DIR}"
    fi
    if command -v make >/dev/null 2>&1; then printf 'DETECT make=found path=%s\n' "$(command -v make)"; else printf 'DETECT make=missing\n'; fi
    if command -v whiptail >/dev/null 2>&1; then printf 'DETECT whiptail=found\n'; else printf 'DETECT whiptail=missing\n'; fi
    if have_nix; then printf 'DETECT nix=found\n'; else printf 'DETECT nix=missing\n'; fi
    printf '  note: `make` is OPTIONAL for Studio — the wizard shells the builder scripts directly;\n'
    printf '  it is only needed by the ncurses menu (--menu) for REAL builds. On SteamOS run from\n'
    printf '  Desktop Mode; the venv lives inside this checkout so the read-only rootfs is untouched.\n'
}

# ── the consent gate (mirrors the .bat's :confirm; default answer is NO) ──────────
confirm() {
    printf '  about to run: %s\n' "$1" >&2
    if [ "${AUTO}" = 1 ]; then printf '  --auto: proceeding without prompt\n' >&2; return 0; fi
    printf '  proceed? [y/N] ' >&2
    local ans=""
    # Prefer the controlling TTY (so a piped stdin can't auto-answer); fall back to stdin,
    # and on EOF/no-tty default to NO — never hang, never silently proceed.
    read -r ans </dev/tty 2>/dev/null || read -r ans 2>/dev/null || ans=""
    case "${ans}" in [Yy]|[Yy][Ee][Ss]) return 0 ;; esac
    printf '  (answer was not y — skipping)\n' >&2
    return 1
}

# Per-family package hints — printed only, NEVER executed (SteamOS has a read-only rootfs /
# empty pacman keyring; we never touch a system package manager for you).
print_install_hint() {
    case "$1" in
        debian) say "fast path (optional): sudo apt install python3 python3-venv python3-pyside6.qtwidgets" ;;
        fedora) say "fast path (optional): sudo dnf install python3 python3-pyside6" ;;
        arch)   say "fast path (optional): sudo pacman -S python python-pyside6  — SKIP on SteamOS (read-only rootfs); use the project-local venv below instead" ;;
    esac
}

# ── consent-gated venv bootstrap: studio/.venv-studio + pip install PySide6 ───────
# Returns 0 on success (QT_SCOPE=venv), 2 if declined, 1 if it failed.
bootstrap_venv() {
    [ -n "${PY_CMD}" ] || die "no Python ${PYTHON_MIN_MAJOR}.${PYTHON_MIN_MINOR}+ found — install python3 first, then re-run."
    say "the Studio GUI needs PySide6 (or an existing PyQt6); it can go into a project-local venv."
    confirm "${PY_CMD} -m venv ${VENV_DIR} && ${VENV_PY} -m pip install -r ${STUDIO_DIR}/requirements.txt" || return 2
    "${PY_CMD}" -m venv "${VENV_DIR}" || { warn "could not create the venv at ${VENV_DIR}"; return 1; }
    "${VENV_PY}" -m pip install -r "${STUDIO_DIR}/requirements.txt" || {
        warn "pip install failed (offline? behind a proxy? missing a system lib for the wheel?) — nothing was retried."
        warn "if a shared library is missing (e.g. libxcb-cursor, libxkbcommon), install the freedesktop"
        warn "runtime (Flatpak) or set LD_LIBRARY_PATH — see docs/NIXOS-STEAMOS.md; we do not auto-install it."
        return 1
    }
    probe_qt
    [ "${QT_SCOPE}" = venv ] || { warn "pip finished but neither PySide6 nor PyQt6 imports from the venv (see output above)."; return 1; }
    return 0
}

# ── launch ───────────────────────────────────────────────────────────────────────
launch_python() {
    local py="$1"; shift
    if in_gamescope; then
        # Game Mode = gamescope/Wayland; Qt needs XWayland. Honour an explicit override.
        export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"
        warn "Game Mode (gamescope) detected — set QT_QPA_PLATFORM=${QT_QPA_PLATFORM} (XWayland)."
        warn "The wizard is keyboard/mouse-heavy; Desktop Mode is recommended."
    fi
    exec "${py}" -m hugmesh_studio "$@"
}

launch_menu() {
    if ! command -v whiptail >/dev/null 2>&1; then
        warn "whiptail (newt) not found — the menu falls back to its plain-text prompt (NO_TUI)."
        warn "for the rich UI: Debian 'apt install whiptail' · Fedora 'dnf install newt' · Arch"
        warn "'pacman -S libnewt' · NixOS: the flake devShell already provides it."
    fi
    if ! command -v make >/dev/null 2>&1; then
        warn "make not found — the menu renders and its python-driven local-mesh submenus work, but"
        warn "REAL image builds need make (get it via 'nix develop' or your package manager)."
    fi
    # build-menu.sh reads env (NO_TUI, IMAGE, …), not argv; forwarding is harmless.
    exec bash "${REPO_DIR}/scripts/build-menu.sh" ${FORWARD[@]+"${FORWARD[@]}"}
}

launch_headless() {
    probe_python || true
    local py=""
    if [ -x "${VENV_PY}" ]; then py="${VENV_PY}"
    elif [ -n "${PY_CMD}" ]; then py="${PY_CMD}"
    else
        die "no Python ${PYTHON_MIN_MAJOR}.${PYTHON_MIN_MINOR}+ on PATH and no venv at ${VENV_DIR}. Headless mode never installs; run scripts/studio-launch.sh with no arguments for guided setup."
    fi
    launch_python "${py}" ${FORWARD[@]+"${FORWARD[@]}"}
}

run_interactive() {
    read_os_release
    local fam; fam="$(distro_family)"

    # NixOS (outside a nix shell): a pip venv of manylinux wheels won't link against a non-FHS
    # /nix interpreter, so we do NOT venv/pip here — Nix supplies python+PySide6+make+whiptail.
    if [ "${fam}" = nixos ] && ! in_nix_shell; then
        probe_python || true
        probe_qt || true
        if [ "${QT_SCOPE}" != none ]; then
            # A nix profile already provides python+Qt — just launch it.
            [ "${QT_SCOPE}" = venv ] && launch_python "${VENV_PY}" ${FORWARD[@]+"${FORWARD[@]}"}
            launch_python "${PY_CMD}" ${FORWARD[@]+"${FORWARD[@]}"}
        fi
        say "NixOS detected (outside a nix shell). Studio needs Python + PySide6 from Nix, not a"
        say "pip venv (impure interpreter; manylinux wheels won't link on a non-FHS host):"
        say "    nix develop            # then: ./scripts/studio-launch.sh   or   make menu"
        say "    nix-shell              # non-flake parity (shell.nix)"
        say "    nix run .#studio       # launch the wizard directly"
        say "    nix run .#menu         # launch the ncurses build menu"
        if have_nix; then
            confirm "nix develop \"${REPO_DIR}\" -c python3 -m hugmesh_studio ${FORWARD[*]-}" \
                && exec nix develop "${REPO_DIR}" -c python3 -m hugmesh_studio ${FORWARD[@]+"${FORWARD[@]}"}
            exit 2
        fi
        die "nix is not on PATH — install Nix (https://nixos.org/download) or use a host with python3 + PySide6."
    fi

    # Everyone else (incl. INSIDE a nix shell): a ready Python + Qt means straight to launch —
    # no report, no prompts (the .bat's fast path).
    probe_python || true
    probe_qt || true
    [ "${QT_SCOPE}" = venv ] && launch_python "${VENV_PY}" ${FORWARD[@]+"${FORWARD[@]}"}
    { [ "${QT_SCOPE}" = system ] && [ -n "${PY_CMD}" ]; } && launch_python "${PY_CMD}" ${FORWARD[@]+"${FORWARD[@]}"}

    # Not ready — DETECT report + a consent-gated project-local venv.
    say "HugMesh Image Studio — Linux setup check (${fam})"
    run_detect
    printf '\n' >&2
    [ "${OS_ID}" = steamos ] && say "SteamOS/Steam Deck: run this from DESKTOP MODE (keyboard/mouse); the venv stays inside this checkout, so the read-only rootfs is never modified — no 'steamos-readonly disable', no pacman."
    print_install_hint "${fam}"
    bootstrap_venv
    local rc=$?
    if [ "${rc}" = 0 ]; then
        launch_python "${VENV_PY}" ${FORWARD[@]+"${FORWARD[@]}"}
    elif [ "${rc}" = 2 ]; then
        say "PySide6 was not installed. Manual setup, then re-run scripts/studio-launch.sh:"
        say "    ${PY_CMD:-python3} -m venv ${VENV_DIR}"
        say "    ${VENV_PY} -m pip install -r ${STUDIO_DIR}/requirements.txt"
        exit 2
    fi
    exit 1
}

# ── dispatch ─────────────────────────────────────────────────────────────────────
# Run only when executed directly; `source`-ing the file (e.g. for tests) just loads
# the functions without launching anything — same guard as scripts/build-menu.sh.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ "${DETECT_ONLY}" = 1 ]; then run_detect; exit 0; fi
    # First-run bootstrap (idempotent; one `cat` when already stamped). Guided and
    # --menu paths only: the headless channel's contract is "no prompts, no installs",
    # and creating PATH symlinks is an install. Advisory by contract — it cannot fail
    # the launch, and everything it prints goes to stderr.
    if [ "${HEADLESS}" = 0 ]; then
        [ "${REDO_FIRST_RUN}" = 1 ] || REDO_FIRST_RUN="$(first_run_wants_redo)"
        first_run_bootstrap "${REPO_DIR}" "${REDO_FIRST_RUN}"
    fi
    if [ "${WANT_MENU}" = 1 ]; then launch_menu; fi     # execs
    if [ "${HEADLESS}" = 1 ]; then launch_headless; fi  # execs
    run_interactive
fi

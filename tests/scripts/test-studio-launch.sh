#!/usr/bin/env bash
# test-studio-launch.sh — hermetic checks for scripts/studio-launch.sh, the portable
# NixOS / SteamOS / Arch / Debian / Fedora launcher (the POSIX sibling of the Windows
# studio/hugmesh-studio.bat).
#
# NOTHING here builds/makes/dockers/installs or touches the network:
#   • --detect only probes (python -c) and prints a report,
#   • the PYTHONPATH proof rides the Qt-free `--print-command` path (no display needed),
#   • --menu runs with NO_TUI + an empty stdin so it renders and quits WITHOUT ever
#     selecting a build target (which would exec `make`),
#   • the venv-bootstrap path is only ever exercised as a DECLINE (no venv is created),
#   • the pure distro-detection functions are unit-tested by SOURCING the launcher (its
#     BASH_SOURCE guard keeps it from launching anything when sourced).
#
#   bash tests/scripts/test-studio-launch.sh
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/../.." && pwd)"
LAUNCH="${REPO_DIR}/scripts/studio-launch.sh"
VENV_DIR="${REPO_DIR}/studio/.venv-studio"
BASH_BIN="$(command -v bash)"

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); }
_bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1" >&2; }
assert_eq()      { [ "$2" = "$3" ] && _ok || _bad "$1: got '$2' want '$3'"; }
assert_grep()    { printf '%s\n' "$2" | grep -Eq -- "$3" && _ok || _bad "$1: missing /$3/"; }
assert_no_venv() { [ -e "${VENV_DIR}" ] && _bad "$1: an unexpected venv exists at ${VENV_DIR}" || _ok; }

# This suite asserts the launcher NEVER bootstraps a venv without consent, so it must
# run with VENV_DIR ABSENT. If a real one already exists (a developer ran the launcher
# and accepted it) we MUST NOT touch it — skip cleanly rather than delete their venv or
# spuriously fail every assert_no_venv. This is exactly the launcher's documented
# purpose, so its presence is normal, not a test failure.
if [ -e "${VENV_DIR}" ]; then
    printf 'SKIP: a venv already exists at %s — this suite needs it absent and will NOT delete your venv. Move it aside to run these tests.\n' "${VENV_DIR}" >&2
    exit 0
fi

# From here VENV_DIR did NOT exist at start, so the EXIT trap can only ever be removing
# a venv the TEST itself caused to appear — a real consent-bypass regression. Fail loudly
# and clean it up so a re-run isn't poisoned.
trap '[ -e "${VENV_DIR}" ] && { printf "ERROR: tests created %s — a launcher path installed without consent\n" "${VENV_DIR}" >&2; rm -rf "${VENV_DIR}"; }' EXIT

# ── 1. static: syntax + the load-bearing PYTHONPATH export ──────────────────────────────
"${BASH_BIN}" -n "${LAUNCH}" && _ok || _bad "bash -n: syntax error"
# The fix vs studio/hugmesh-studio:3-4 (which computed `here` but never used it): the
# launcher MUST export PYTHONPATH=$REPO/studio so the module resolves from any CWD.
grep -q 'export PYTHONPATH="${STUDIO_DIR}' "${LAUNCH}" \
    && _ok || _bad "launcher must export PYTHONPATH=studio (the load-bearing CWD fix)"

# ── 2. --detect: reports, exits 0, installs nothing ─────────────────────────────────────
det="$("${BASH_BIN}" "${LAUNCH}" --detect 2>&1)"; drc=$?
assert_eq   "detect: exit 0"           "${drc}" 0
assert_grep "detect: os line"          "${det}" '^DETECT os=.* family=.* nix_shell=[01] gamescope=[01]$'
assert_grep "detect: python line"      "${det}" '^DETECT python='
assert_grep "detect: qt line"          "${det}" '^DETECT qt='
assert_grep "detect: venv line"        "${det}" '^DETECT venv='
assert_grep "detect: make line"        "${det}" '^DETECT make='
assert_grep "detect: whiptail line"    "${det}" '^DETECT whiptail='
assert_grep "detect: nix line"         "${det}" '^DETECT nix='
assert_no_venv "detect"

# ── 3. PYTHONPATH proof: --print-command reaches the module from an UNRELATED cwd ───────
# --print-command is a --arg other than --detect/--auto/--menu, so it takes the HEADLESS
# path straight to `python3 -m hugmesh_studio` and emits a builder command line.
scratch="$(mktemp -d)"
pc="$(cd "${scratch}" && "${BASH_BIN}" "${LAUNCH}" --print-command --backend native 2>/dev/null)"; prc=$?
assert_eq   "print-command: exit 0"        "${prc}" 0
assert_grep "print-command: builder emitted" "${pc}" 'build-[a-z0-9-]+-stage4\.sh'
# Contrast: WITHOUT the launcher's PYTHONPATH export, the same module import fails from an
# unrelated cwd — this is exactly the gap studio-launch.sh closes.
( cd "${scratch}" && env -u PYTHONPATH python3 -m hugmesh_studio --print-command ) >/dev/null 2>&1
crc=$?
[ "${crc}" -ne 0 ] && _ok || _bad "contrast: bare 'python3 -m hugmesh_studio' unexpectedly imported from ${scratch}"
rm -rf "${scratch}"

# ── 4. --menu: hands off to the ncurses menu, renders + quits under NO_TUI ──────────────
menu_state="$(mktemp -d)"
mo="$(SNAP_MENU_STATE="${menu_state}" NO_TUI=1 "${BASH_BIN}" "${LAUNCH}" --menu </dev/null 2>&1)"; mrc=$?
assert_eq   "menu: exit 0"           "${mrc}" 0
assert_grep "menu: rendered Main"    "${mo}" '== Main =='
assert_no_venv "menu"
rm -rf "${menu_state}"

# ── 5. headless with NO Python: errors out, NEVER installs ──────────────────────────────
# Shadow PATH with a dir holding only `dirname` (the launcher's single top-level external),
# so no python3 candidate is found. Headless must exit non-zero and never bootstrap a venv.
bindir="$(mktemp -d)"
ln -s "$(command -v dirname)" "${bindir}/dirname"
ho="$(PATH="${bindir}" "${BASH_BIN}" "${LAUNCH}" --print-command 2>&1)"; hrc=$?
assert_eq   "headless-no-python: exit 1"   "${hrc}" 1
assert_grep "headless-no-python: never installs" "${ho}" 'never installs'
assert_no_venv "headless-no-python"
rm -rf "${bindir}"

# ── 5b. arg classification: interactive GUI modes take the GUIDED path, not headless ────
# Source in a subshell with the flag as $@ (the guard skips dispatch), then read HEADLESS.
_headless_for() { ( set -- "$1"; source "${LAUNCH}" >/dev/null 2>&1; printf '%s' "${HEADLESS}" ); }
for f in --go-live --fleet --tray --stack-tray --dev; do
    assert_eq "gui-mode ${f} keeps the guided (non-headless) path" "$(_headless_for "${f}")" 0
done
for f in --print-command --print-specs --login-agent --askpass; do
    assert_eq "headless ${f} stays headless" "$(_headless_for "${f}")" 1
done

# ── 6. pure detection functions (SOURCE the launcher; its guard suppresses launching) ───
# shellcheck disable=SC1090
source "${LAUNCH}"
unset PYTHONPATH   # the source computed a bogus PYTHONPATH off $0; keep the env clean

assert_eq "family: nixos"                "$(OS_ID=nixos    OS_ID_LIKE=''             distro_family)" nixos
assert_eq "family: steamos->arch"        "$(OS_ID=steamos  OS_ID_LIKE='arch'         distro_family)" arch
assert_eq "family: arch"                 "$(OS_ID=arch     OS_ID_LIKE=''             distro_family)" arch
assert_eq "family: ubuntu->debian"       "$(OS_ID=ubuntu   OS_ID_LIKE='debian'       distro_family)" debian
assert_eq "family: mint(id_like)->debian" "$(OS_ID=linuxmint OS_ID_LIKE='ubuntu debian' distro_family)" debian
assert_eq "family: fedora"               "$(OS_ID=fedora   OS_ID_LIKE=''             distro_family)" fedora
assert_eq "family: bazzite->fedora"      "$(OS_ID=bazzite  OS_ID_LIKE='fedora'       distro_family)" fedora
assert_eq "family: gentoo->unknown"      "$(OS_ID=gentoo   OS_ID_LIKE=''             distro_family)" unknown
assert_eq "family: id_like arch->arch"   "$(OS_ID=cachyos  OS_ID_LIKE='arch'         distro_family)" arch

# id_matches: exact ID or an ID_LIKE token
OS_ID=pop OS_ID_LIKE='ubuntu debian' id_matches debian && _ok || _bad "id_matches: 'debian' in ID_LIKE"
OS_ID=pop OS_ID_LIKE='ubuntu debian' id_matches suse   && _bad "id_matches: 'suse' should not match" || _ok

# in_gamescope: XDG_CURRENT_DESKTOP or $GAMESCOPE_WAYLAND_DISPLAY
XDG_CURRENT_DESKTOP=gamescope in_gamescope && _ok || _bad "in_gamescope: XDG_CURRENT_DESKTOP=gamescope"
( unset XDG_CURRENT_DESKTOP; GAMESCOPE_WAYLAND_DISPLAY=gamescope-0 in_gamescope ) && _ok || _bad "in_gamescope: GAMESCOPE_WAYLAND_DISPLAY set"
( unset XDG_CURRENT_DESKTOP GAMESCOPE_WAYLAND_DISPLAY; in_gamescope ) && _bad "in_gamescope: false when neither set" || _ok

# ── 7. the consent gate (confirm): --auto accepts, otherwise default is NO ──────────────
AUTO=1
confirm "echo test" >/dev/null 2>&1 && _ok || _bad "confirm: --auto must accept without prompting"
AUTO=0
if ! : 2>/dev/null </dev/tty; then
    # No controlling tty -> confirm reads stdin; verify decline (default) and accept.
    printf 'n\n' | confirm "echo test" >/dev/null 2>&1 && _bad "confirm: 'n' must decline (return 1)" || _ok
    printf 'y\n' | confirm "echo test" >/dev/null 2>&1 && _ok || _bad "confirm: 'y' must accept"
    printf '\n'  | confirm "echo test" >/dev/null 2>&1 && _bad "confirm: empty answer must default to NO" || _ok
else
    _ok; _ok; _ok
    printf 'SKIP confirm decline/accept: a controlling /dev/tty is present\n' >&2
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]

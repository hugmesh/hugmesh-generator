#!/usr/bin/env bash
# build-flatpak-local.sh — build the HugMesh Image Studio Flatpak from this checkout,
# install it and run it, on a machine with no sudo, no apt and no flatpak-builder package.
#
#   studio/packaging/build-flatpak-local.sh
#
# What it does, in order, and stops at the first step that fails:
#   1. adds flathub to a PRIVATE flatpak user directory and installs three things there:
#      org.flatpak.Builder (flatpak-builder, as a flatpak), and the runtime and SDK the
#      manifest names (org.kde.Platform / org.kde.Sdk, branch read from the manifest);
#   2. runs desktop-file-validate and `appstreamcli validate --no-net` (what the release
#      workflow runs);
#   3. builds org.hugmesh.ImageStudio from flatpak/org.hugmesh.ImageStudio.yml;
#   4. exports hugmesh-studio-<version>-<arch>.flatpak and its .sha256 (same names and
#      same flatpak build-bundle call as the release workflow, except that the bundle is
#      written as <name>.partial and renamed when whole);
#   5. installs that bundle into the private directory and runs it:
#        --print-specs must print JSON (the release workflow's smoke test), and Qt must
#        start on its offscreen platform with the PySide6 bindings and the package's data
#        files present (the part --print-specs cannot see, because it never loads Qt).
#
# It never calls sudo, apt or any package manager, never writes to your own flatpak
# directory (it refuses to run if pointed at it), and needs only the `flatpak` program.
# Everything goes under two directories, both overridable:
#   HUGMESH_STUDIO_FLATPAK_USER_DIR  the private flatpak user directory
#                                    (default $HOME/.hugmesh-wt-local/flatpak-studio, ~10 GiB)
#   HUGMESH_STUDIO_FLATPAK_OUT       bundle, checksum and build state
#                                    (default $HOME/.hugmesh-wt-local/dist-studio, ~2 GiB)
#   HUGMESH_STUDIO_FLATPAK_MIN_FREE_GIB  refuse to start with less free space than this
#                                    (default 14 on a first run, 4 once the runtimes exist)
# Running a flatpak app also creates ~/.var/app/<app-id> in your real home whatever
# FLATPAK_USER_DIR says; that holds only the data of the two apps used here.
#
# WHY flatpak-builder RUNS THE WAY IT DOES. flatpak-builder is installed as a flatpak and
# a flatpak sandbox may not create another sandbox (its seccomp filter blocks unshare and
# friends), so the Builder asks the HOST flatpak to do it, through flatpak-spawn --host.
# Two things follow, and both are handled below:
#   * The Builder's own wrapper (flatpak-builder-wrapper) forces FLATPAK_USER_DIR to
#     $HOME/.local/share/flatpak, which is YOUR flatpak directory. We bypass it and call
#     flatpak-builder directly.
#   * The host command starts from the host session's environment, not the Builder's, so
#     it would not see the private directory. FLATPAK_BINARY points at a tiny script on
#     the host that pins FLATPAK_USER_DIR and then runs the real flatpak.
# Flatpak also hides the active user-installation directory from every sandbox unless it
# is granted by name, hence --filesystem=<private dir> on each flatpak run of the Builder.
#
# From the top of the file to the `flatpak` check only shell builtins run (--help aside),
# so the early refusals can be tested with a bare PATH: tests/test_flatpak_packaging_files.py.
#
# Exit codes: 0 built, installed and verified; 1 a step failed; 2 bad usage.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: studio/packaging/build-flatpak-local.sh [-h|--help]

Builds the HugMesh Image Studio Flatpak from this checkout, exports it as
hugmesh-studio-<version>-<arch>.flatpak with a .sha256, installs it into a private
flatpak directory and runs it. Needs only the flatpak program; no sudo, no apt.

Environment (all optional):
  HUGMESH_STUDIO_FLATPAK_USER_DIR      private flatpak user directory
                                       (default: $HOME/.hugmesh-wt-local/flatpak-studio)
  HUGMESH_STUDIO_FLATPAK_OUT           bundle, checksum and build state
                                       (default: $HOME/.hugmesh-wt-local/dist-studio)
  HUGMESH_STUDIO_FLATPAK_MIN_FREE_GIB  refuse to start with less free space
                                       (default: 14 on a first run, 4 afterwards)
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown argument: %s\n\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
done

STEP="checking the request and the paths"
step() { STEP="$1"; printf '\n==> %s\n' "$1"; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
# Seen once during development: flatpak's session helper kept running but its directory
# under $XDG_RUNTIME_DIR vanished, and from then on EVERY flatpak sandbox failed to start
# with only "bwrap: Can't find source path .../.flatpak-helper/monitor". A restart of the
# helper fixes it (it starts again on demand), so say so instead of leaving that line alone.
helper_hint() {
    command -v pgrep >/dev/null 2>&1 || return 0
    local run_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" pids
    [ ! -d "$run_dir/.flatpak-helper/monitor" ] || return 0
    pids="$(pgrep -u "$(id -u)" -f flatpak-session-helper || true)"
    [ -n "$pids" ] || return 0
    pids="$(printf '%s' "$pids" | tr '\n' ' ')"
    printf '\nnote: flatpak'\''s session helper is running (pid %s) but %s is missing.\n' \
        "$pids" "$run_dir/.flatpak-helper/monitor" >&2
    printf 'While that is so, every flatpak sandbox fails to start. The helper restarts on demand:\n' >&2
    printf '  kill %s\n' "$pids" >&2
}
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '\nFAILED during: %s (exit %d)\n' "$STEP" "$rc" >&2
        helper_hint
    fi
}
trap on_exit EXIT

command -v flatpak >/dev/null 2>&1 \
    || die "the flatpak program is not installed. It is the one thing this script needs from the host (flatpak-builder, sudo and apt are not needed)."
command -v realpath >/dev/null 2>&1 || die "realpath is not installed (GNU coreutils)"

# ---- where everything lives ---------------------------------------------------------
self="${BASH_SOURCE[0]}"
case "$self" in */*) self_dir="${self%/*}" ;; *) self_dir="." ;; esac
here="$(cd -- "$self_dir" && pwd -P)"                 # .../studio/packaging
studio_dir="$(cd -- "$here/.." && pwd -P)"
flatpak_src="$here/flatpak"
manifest="$flatpak_src/org.hugmesh.ImageStudio.yml"

root_default="${HOME:?HOME is not set}/.hugmesh-wt-local"
user_dir="$(realpath -m -- "${HUGMESH_STUDIO_FLATPAK_USER_DIR:-$root_default/flatpak-studio}")"
out_dir="$(realpath -m -- "${HUGMESH_STUDIO_FLATPAK_OUT:-$root_default/dist-studio}")"
work="$out_dir/flatpak-work"

# Never point this at a flatpak directory somebody already uses: it would install a build
# toolchain, an app and a remote into it. Refuse the same directory, one inside it and
# one that contains it (flatpak would then share a parent with, say, ~/.local/share).
nested() {
    case "$1/" in "$2/"*) return 0 ;; esac
    case "$2/" in "$1/"*) return 0 ;; esac
    return 1
}
for protected in "$(realpath -m -- "${XDG_DATA_HOME:-$HOME/.local/share}/flatpak")" \
                 "$(realpath -m -- "$HOME/.local/share/flatpak")" \
                 "/var/lib/flatpak"; do
    if nested "$user_dir" "$protected"; then
        die "HUGMESH_STUDIO_FLATPAK_USER_DIR ($user_dir) is, is inside, or contains $protected. This script installs into a private directory so your own flatpak data is never touched; pick another one."
    fi
done
# The build state is not flatpak data: keep it out of the directory flatpak manages.
if nested "$out_dir" "$user_dir"; then
    die "HUGMESH_STUDIO_FLATPAK_OUT ($out_dir) is, is inside, or contains the private flatpak directory ($user_dir); keep the build output in a directory of its own."
fi

# ---- facts come from the manifest and __init__.py, never from this script --------------
manifest_value() {   # the value of a top-level `key: value` line, quotes and comment stripped
    sed -n -E "/^$1:/{s/^$1:[[:space:]]*[\"']?([^\"'[:space:]#]+)[\"']?[[:space:]]*(#.*)?\$/\\1/p;q;}" "$manifest"
}
for needed in "$manifest" "$flatpak_src/python-deps.json" \
              "$flatpak_src/org.hugmesh.ImageStudio.desktop" \
              "$flatpak_src/org.hugmesh.ImageStudio.metainfo.xml" \
              "$studio_dir/hugmesh_studio/__init__.py"; do
    [ -f "$needed" ] || die "missing $needed (is this a complete checkout?)"
done
app_id="$(manifest_value app-id)"
runtime="$(manifest_value runtime)"
runtime_version="$(manifest_value runtime-version)"
sdk="$(manifest_value sdk)"
app_command="$(manifest_value command)"
version="$(sed -n -E '/^__version__ = /{s/^__version__ = "([^"]+)".*/\1/p;q;}' "$studio_dir/hugmesh_studio/__init__.py")"
for fact in app_id runtime runtime_version sdk app_command version; do
    [ -n "${!fact}" ] || die "could not read '$fact' from the manifest or hugmesh_studio/__init__.py"
done
arch="$(flatpak --default-arch)"
bundle_name="hugmesh-studio-${version}-${arch}.flatpak"
bundle="$out_dir/$bundle_name"

# ---- preflight ----------------------------------------------------------------------------
step "Checking this machine"
for tool in python3 sha256sum sed awk df flock id; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done
# The Builder reaches the host through the flatpak session helper, which is a service on
# the user's D-Bus session bus: a normal desktop login has one, a bare ssh session may not.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ ! -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ]; then
    die "no D-Bus session bus. The Builder needs it to reach the host flatpak (flatpak-spawn --host); run this from a desktop login or under dbus-run-session."
fi
mkdir -p "$out_dir" "$user_dir"
# Two runs at once would fight over one build directory and one bundle file.
exec 9>"$out_dir/.build-flatpak-local.lock"
flock -n 9 || die "another build-flatpak-local.sh is already using $out_dir"

export FLATPAK_USER_DIR="$user_dir"
flatpak_bin="$(command -v flatpak)"

free_gib() {   # free GiB on the filesystem that holds $1 (or its nearest existing parent)
    local p="$1"
    while [ ! -d "$p" ]; do p="$(dirname -- "$p")"; done
    df -Pk -- "$p" | awk 'NR==2 { print int($4 / 1048576) }'
}

printf 'flatpak:        %s (%s)\n' "$(flatpak --version)" "$flatpak_bin"
printf 'app:            %s %s (%s)\n' "$app_id" "$version" "$arch"
printf 'runtime / sdk:  %s//%s and %s//%s\n' "$runtime" "$runtime_version" "$sdk" "$runtime_version"
printf 'private dir:    %s\n' "$user_dir"
printf 'output dir:     %s\n' "$out_dir"

# ---- 1. the private flatpak directory --------------------------------------------------
# Skipped when the remote is already there (remote-add --if-not-exists still fetches the
# .flatpakrepo first). A re-run still goes to flathub: the bundle install at step 5 fetches
# the runtime's related extensions (the GL drivers) from the remote every time.
remotes="$(flatpak remotes --user --columns=name)"
case $'\n'"$remotes"$'\n' in
    *$'\nflathub\n'*) ;;
    *)
        step "Adding the flathub remote to the private flatpak directory"
        flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        ;;
esac

wanted_refs=("org.flatpak.Builder//stable" "$runtime//$runtime_version" "$sdk//$runtime_version")
missing_refs=()
for ref in "${wanted_refs[@]}"; do
    flatpak info --user "$ref" >/dev/null 2>&1 || missing_refs+=("$ref")
done

step "Checking free space"
min_free="${HUGMESH_STUDIO_FLATPAK_MIN_FREE_GIB:-}"
case "$min_free" in
    "") if [ "${#missing_refs[@]}" -gt 0 ]; then min_free=14; else min_free=4; fi ;;
    *[!0-9]*) die "HUGMESH_STUDIO_FLATPAK_MIN_FREE_GIB must be a whole number of GiB, not '$min_free'" ;;
esac
for dir in "$user_dir" "$out_dir"; do
    have="$(free_gib "$dir")"
    [ "$have" -ge "$min_free" ] \
        || die "only ${have} GiB free where $dir lives and the build wants ${min_free} GiB (a first run is about 12 GiB: runtimes 9.5, build state 1.9, bundle 0.2). Free some space or set HUGMESH_STUDIO_FLATPAK_USER_DIR / HUGMESH_STUDIO_FLATPAK_OUT elsewhere."
done

if [ "${#missing_refs[@]}" -gt 0 ]; then
    step "Installing into the private directory: ${missing_refs[*]} (several GB; the slow part of a first run)"
    # Flathub marks old runtime branches end-of-life and says so here; they still install.
    flatpak install --user -y --noninteractive flathub "${missing_refs[@]}"
else
    step "Builder, runtime and SDK are already installed in the private directory"
fi

# ---- 2. the same validators the release workflow runs ------------------------------------
# Preferably the host's copy; otherwise the one inside the Builder flatpak, which ships both.
run_validator() {
    local tool="$1"
    shift
    if command -v "$tool" >/dev/null 2>&1; then
        "$tool" "$@"
    else
        printf '(%s is not installed here; using the copy inside org.flatpak.Builder)\n' "$tool"
        flatpak run --user --filesystem="$user_dir" --env=FLATPAK_USER_DIR="$user_dir" \
            --command="$tool" org.flatpak.Builder "$@"
    fi
}
step "Validating the desktop entry and the AppStream metadata"
run_validator desktop-file-validate "$flatpak_src/$app_id.desktop"
# --no-net, as in the workflow: the only remaining complaints would be URL reachability.
run_validator appstreamcli validate --no-net "$flatpak_src/$app_id.metainfo.xml"

# ---- 3. build ---------------------------------------------------------------------------------
sh_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
step "Preparing the Builder"
mkdir -p "$work/bin"
wrapper="$work/bin/flatpak-private"
{
    printf '#!/bin/sh\n'
    printf '# Written by build-flatpak-local.sh. Runs the HOST flatpak against the private directory.\n'
    printf 'FLATPAK_USER_DIR=%s\nexport FLATPAK_USER_DIR\n' "$(sh_quote "$user_dir")"
    printf 'exec %s "$@"\n' "$(sh_quote "$flatpak_bin")"
} > "$wrapper"
chmod 755 "$wrapper"
# The Builder runs with $work as its working directory and no --state-dir, so its state
# is $work/.flatpak-builder (as in the release workflow's in-tree build). With --state-dir
# it would name its cache branch after the manifest's ABSOLUTE path instead, one file
# under refs/heads whose name grows with the checkout path, and on an encrypted home
# (eCryptfs allows 143 bytes per file name) any checkout path over 77 bytes then failed
# with a bare "File name too long" after the whole toolchain had been installed.
builder=(flatpak run --user --cwd="$work"
         --filesystem="$user_dir" --filesystem="$out_dir"
         --env=FLATPAK_USER_DIR="$user_dir" --env=FLATPAK_BINARY="$wrapper")
# One cheap round trip proves the whole route (Builder starts, session helper answers,
# the wrapper runs on the host) before the long build depends on it.
if ! "${builder[@]}" --command=flatpak-spawn org.flatpak.Builder --host "$wrapper" --version; then
    die "the Builder could not run a command on the host through flatpak-spawn --host. It needs the flatpak session helper (org.freedesktop.Flatpak) on your D-Bus session."
fi

step "Building $app_id (downloads the pinned PySide6 wheels, installs the app, renders the icons)"
"${builder[@]}" --command=flatpak-builder org.flatpak.Builder \
    --user --disable-rofiles-fuse --force-clean \
    --repo="$work/repo" "$work/build-dir" "$manifest" \
    2>&1 | tee "$work/build.log"

# ---- 4. the bundle -----------------------------------------------------------------------------
# --runtime-repo, as in the release workflow: the bundle records where its runtime comes
# from, so `flatpak install` on a machine without that runtime adds the remote and fetches
# it instead of stopping at "requires the runtime ... which was not found".
runtime_repo_url="https://dl.flathub.org/repo/flathub.flatpakrepo"
step "Exporting $bundle_name (compresses about 650 MB: a few minutes on one CPU)"
rm -f "$bundle" "$bundle.partial" "$bundle.sha256"
flatpak build-bundle --runtime-repo="$runtime_repo_url" "$work/repo" "$bundle.partial" "$app_id"
mv -f "$bundle.partial" "$bundle"
( cd "$out_dir" && sha256sum "$bundle_name" | tee "$bundle_name.sha256" && sha256sum -c "$bundle_name.sha256" )

# ---- 5. install it and run it -----------------------------------------------------------------
step "Installing the bundle into the private directory"
if flatpak info --user "$app_id" >/dev/null 2>&1; then
    flatpak uninstall --user -y --noninteractive "$app_id"
fi
flatpak install --user -y --noninteractive --bundle "$bundle"

step "Smoke test 1 of 3: $app_command --print-specs must print JSON inside the sandbox"
specs="$work/print-specs.jsonl"
flatpak run --user --command="$app_command" "$app_id" --print-specs > "$specs"
[ -s "$specs" ] || die "no output from --print-specs: the installed bundle is incomplete"
python3 - "$specs" <<'PY'
import json, sys
lines = [ln for ln in open(sys.argv[1], encoding="utf-8").read().splitlines() if ln.strip()]
if not lines:
    sys.exit("--print-specs printed only blank lines")
for number, line in enumerate(lines, 1):
    try:
        obj = json.loads(line)
    except ValueError as exc:
        sys.exit(f"--print-specs line {number} is not JSON: {exc}")
    if not isinstance(obj, dict) or not obj:
        sys.exit(f"--print-specs line {number} is not a non-empty JSON object")
print(f"{len(lines)} JSON object(s), {len(lines[0])} bytes in the first")
PY

step "Smoke test 2 of 3: Qt starts inside the sandbox, with PySide6 and the package data"
# --print-specs never loads Qt, so on its own it would pass with PySide6 missing entirely.
# --nofilesystem=host keeps this check inside the sandbox: it reads and writes none of
# your files. QT_QPA_PLATFORM=offscreen means no display is needed or touched.
qt_out="$(flatpak run --user --nofilesystem=host --env=QT_QPA_PLATFORM=offscreen \
    --command=python3 "$app_id" - <<'PY'
import os, sys
import hugmesh_studio
from hugmesh_studio.gui.qt import QtCore, QtWidgets, BINDING

package = os.path.dirname(hugmesh_studio.__file__)
expected = ["core/device-catalog.json", "core/progress-tables.json", "core/_roles-lib.sh"]
missing = [p for p in expected if not os.path.isfile(os.path.join(package, p))]
html = [f for f in os.listdir(os.path.join(package, "assets")) if f.endswith(".html")]
if missing or not html:
    sys.exit(f"package data missing from the install: {missing or 'assets/*.html'}")
app = QtWidgets.QApplication(["flatpak-smoke"])
label = QtWidgets.QLabel("smoke")
label.resize(120, 40)
label.show()
shot = label.grab()
# PySide6 is a licensing decision (LGPL), not a preference: a PyQt6 fallback would pass
# every other check and quietly relicense the bundle.
if BINDING != "PySide6" or app.platformName() != "offscreen" or shot.isNull():
    sys.exit(f"unexpected Qt state: binding={BINDING} platform={app.platformName()} "
             f"grab_null={shot.isNull()}")
print(f"qt-ok binding={BINDING} qt={QtCore.qVersion()} platform={app.platformName()} "
      f"grab={shot.width()}x{shot.height()} html_assets={len(html)}")
PY
)"
printf '%s\n' "$qt_out"
case "$qt_out" in *"qt-ok binding=PySide6"*) ;; *) die "the Qt smoke test did not report qt-ok" ;; esac

step "Smoke test 3 of 3: the launcher, metadata and icons are installed and exported"
wanted_files=("/app/bin/$app_command"
              "/app/share/applications/$app_id.desktop"
              "/app/share/metainfo/$app_id.metainfo.xml"
              "/app/share/icons/hicolor/16x16/apps/$app_id.png"
              "/app/share/icons/hicolor/256x256/apps/$app_id.png")
# The shell INSIDE the sandbox prints the paths it finds, one per line, and this side
# decides: a file it did not print is missing, and so is every file if it printed nothing.
# shellcheck disable=SC2016
present_files="$(flatpak run --user --nofilesystem=host --command=sh "$app_id" -c '
    for f in "$@"; do [ -e "$f" ] && echo "$f"; done; exit 0' _ "${wanted_files[@]}")"
missing_files=0
for f in "${wanted_files[@]}"; do
    case $'\n'"$present_files"$'\n' in
        *$'\n'"$f"$'\n'*) printf 'ok       %s\n' "$f" ;;
        *) printf 'MISSING  %s\n' "$f"; missing_files=$((missing_files + 1)) ;;
    esac
done
[ "$missing_files" -eq 0 ] || die "$missing_files of ${#wanted_files[@]} files are missing from the installed app"
[ -f "$user_dir/exports/share/applications/$app_id.desktop" ] \
    || die "flatpak did not export $app_id.desktop into $user_dir/exports"
printf 'ok       %s\n' "$user_dir/exports/share/applications/$app_id.desktop"

# ---- done ---------------------------------------------------------------------------------------------
step "Done in ${SECONDS}s"
commit="$(flatpak info --user --show-commit "$app_id")"
printf 'bundle:     %s\n' "$bundle"
printf 'sha256:     %s\n' "$(awk '{ print $1 }' "$bundle.sha256")"
printf 'size:       %s bytes\n' "$(wc -c < "$bundle" | tr -d ' ')"
printf 'installed:  app/%s/%s/master, commit %s\n' "$app_id" "$arch" "$commit"
printf 'run it:     FLATPAK_USER_DIR=%s flatpak run --user %s\n' "$(sh_quote "$user_dir")" "$app_id"
printf 'remove all: rm -rf %s %s\n' "$(sh_quote "$user_dir")" "$(sh_quote "$work")"

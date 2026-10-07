#!/usr/bin/env bash
# build-msi-wine.sh - build hugmesh-studio-<version>-x64.msi on a Linux machine that has
# Docker and Wine and no Windows, from a clean checkout, with one command.
#
#   studio/packaging/build-msi-wine.sh            # every phase, in order
#   studio/packaging/build-msi-wine.sh freeze     # or just some of them (see PHASES)
#
# It repeats what .github/workflows/studio-release.yml's `msi` job does, with a Windows
# CPython and the Windows build of WiX both running under Wine in a PRIVATE prefix:
#
#   PyInstaller freeze of packaging/hugmesh-studio.spec  ->  dist/hugmesh-studio/
#   smoke tests of the frozen app                        (CLI, file tree, and its window)
#   wix build of Package.wxs + Files.wxs                 ->  hugmesh-studio-<v>-x64.msi
#   structural checks of the MSI with msitools           (no Windows, no WiX, no Wine)
#   install, run and uninstall it with Wine's own msiexec
#
# WHY NOT JUST RUN THE WORKFLOW'S STEPS. Measured on 2026-09-30, three of them cannot
# work as written, wherever they run, so this script does not copy them:
#   * `wix harvest files ...` - no release of the wix tool has a `harvest` command
#     (4.0.0 through 7.0.0). Files.wxs harvests with WiX's own <Files> element instead.
#   * an unpinned `dotnet tool install --global wix` now installs WiX 7, which refuses
#     to run until the Open Source Maintenance Fee EULA is accepted (WIX7015). Accepting
#     a licence is the project owner's decision, not a build script's, so this pins 6.0.2
#     (the last release before that gate).
#   * the workflow adds WixToolset.Util.wixext (unused, and unpinned: it pulled 7.0.0 into
#     a 6.x tool) but builds with -ext WixToolset.UI.wixext, which it never adds
#     (WIX0144). This installs the UI extension at the same version as the tool.
# And WiX itself cannot run natively on Linux: it validates every Directory/@Name with a
# Windows path trick that always fails there (WIX0389), and its cabinet and MSI code call
# Windows DLLs. So WiX runs under Wine, on Microsoft's Windows .NET 8 runtime.
#
# THE PINS BELOW ARE THE POINT. Every download is checked against a hash written in this
# file, on every run, not just the first. Python packages are installed by hash from
# wix/windows-build-requirements.txt. Nothing is taken on trust from "latest".
#
# THIS IS NOT PROOF OF A WORKING WINDOWS INSTALLER. The MSI was written by WiX running
# under Wine (Wine's msi.dll and cabinet.dll, MSZIP compression since Wine's cabinet
# code cannot do LZX), and no real Windows Installer, SmartScreen, ICE validation or
# signing has seen it. What IS proved is listed in wix/README.md.
#
# PHASES (default: all but selftest)
#   fetch         download and hash-check Python, the .NET runtime and WiX
#   prefix        create the private Wine prefix; install Python, the locked packages,
#                 the .NET runtime, WiX and the UI extension into it
#   freeze        copy the checkout, render the icon, run PyInstaller, smoke-test it
#   msi           license page, wix build, SHA-256 file
#   verify        msitools checks of the MSI against the frozen tree (needs Docker)
#   install-test  install, run and uninstall the MSI with Wine's msiexec
#   selftest      NOT in the default run: break the bundle and the MSI on purpose and
#                 insist that the smoke tests and the verifier turn red
#
# ENVIRONMENT (all optional)
#   HUGMESH_MSI_WORKDIR   scratch, downloads, prefix and build trees
#                         (default ${XDG_CACHE_HOME:-~/.cache}/hugmesh-studio-msi)
#   HUGMESH_WINE_PREFIX   the private Wine prefix (default $HUGMESH_MSI_WORKDIR/wine-prefix).
#                         REFUSED if it is, or is inside, ~/.wine, or if it exists, is not
#                         empty and this script did not create it.
#   HUGMESH_DIST_DIR      where the .msi and .msi.sha256 land (default $HUGMESH_MSI_WORKDIR/dist)
#   HUGMESH_WINE / HUGMESH_WINESERVER / HUGMESH_DOCKER   the tools (defaults wine, wineserver, docker)
#   HUGMESH_GUI_SMOKE     auto (default: run it if xdotool exists), 1 (require it), 0 (skip)
#   HUGMESH_WINEDEBUG     WINEDEBUG for every Wine call (default -all)
#   HUGMESH_WINE_FONT_DIR a folder holding tahoma.ttf and tahomabd.ttf if Wine's own are not
#                         where this script looks (the icon's letter is drawn with them)
#
# Needs: wine (Windows 10 or later personality), Xvfb, curl, tar, python3 (any 3.8+), docker,
# and for the window check xdotool (ImageMagick `import` adds a screenshot). No sudo.
set -Eeuo pipefail

# ---- pins ---------------------------------------------------------------------------------
PYTHON_VERSION=3.12.10                    # the last 3.12 with Windows installers (3.12.11+ are source-only)
PYTHON_URL=https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe
# python.org publishes only an MD5 for this file (5eddb0b6f12c852725de071ae681dde4, matched), a
# GPG signature and a Sigstore bundle, no SHA-256. This digest was computed from the file after
# checking the MD5 and the detached signature against Steve Dower's key, fingerprint
# 7ED10B6531D7C8E1BC296021FC624643487034E5, which python.org's OpenPGP page publishes.
PYTHON_SHA256=67b5635e80ea51072b87941312d00ec8927c4db9ba18938f7ad2d27b328b95fb
DOTNET_VERSION=8.0.31                     # runtime only; digest is Microsoft's own release metadata
DOTNET_URL=https://builds.dotnet.microsoft.com/dotnet/Runtime/8.0.31/dotnet-runtime-8.0.31-win-x64.zip
DOTNET_SHA512=9c55c58694676ee64b0eed2cd6d8cbf58b9aa8288420acc66841e15ca0099c75d4af0182d23a641c2342e5a151a325df4a12fa0bde2e47c0fb7e9a33e7b09896
WIX_VERSION=6.0.2                         # MS-RL; 7.x needs an EULA acceptance (see above)
WIX_URL=https://api.nuget.org/v3-flatcontainer/wix/6.0.2/wix.6.0.2.nupkg
WIX_SHA512=b4536ece74dc7ea01d5c809813456914f650d02607a70feec0875742d34756514673016659317788410bc54d47aeba1b131f1367accc7f2ae81bd07fe43560e6
WIXUI_URL=https://api.nuget.org/v3-flatcontainer/wixtoolset.ui.wixext/6.0.2/wixtoolset.ui.wixext.6.0.2.nupkg
WIXUI_SHA512=769af5c9387939370d94b2a26b5a372560f6c14dc29df147cee03714ac916d1198def3083e4bdd961d82c7b0414465d53c1d85cfd0654456a5b48d067f7b3cc0
# msitools runs in a throwaway container from this exact image; apt verifies its own packages.
MSITOOLS_IMAGE=debian@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

# ---- where things are -----------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
STUDIO_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
REPO_DIR=$(cd "$STUDIO_DIR/.." && pwd -P)
WIX_SRC_DIR=$SCRIPT_DIR/wix

: "${HUGMESH_MSI_WORKDIR:=${XDG_CACHE_HOME:-$HOME/.cache}/hugmesh-studio-msi}"
: "${HUGMESH_WINE_PREFIX:=$HUGMESH_MSI_WORKDIR/wine-prefix}"
: "${HUGMESH_DIST_DIR:=$HUGMESH_MSI_WORKDIR/dist}"
: "${HUGMESH_WINE:=wine}"
: "${HUGMESH_WINESERVER:=wineserver}"
: "${HUGMESH_DOCKER:=docker}"
: "${HUGMESH_GUI_SMOKE:=auto}"
: "${HUGMESH_WINEDEBUG:=-all}"

DL=$HUGMESH_MSI_WORKDIR/downloads
BUILD=$HUGMESH_MSI_WORKDIR/build
SRC=$BUILD/src                              # the copy of the checkout we freeze: mirrors CI's layout
LOGS=$BUILD/logs
DIST_APP=$SRC/studio/dist/hugmesh-studio    # the PyInstaller onedir
PREFIX_MARK=.hugmesh-studio-msi-prefix
PYEXE='C:\Python312\python.exe'
WIX_DLL='C:\wix\wix.dll'
WIXUI_DLL='C:\wixext\ui\WixToolset.UI.wixext.dll'

VERSION=$(sed -n 's/^__version__ = "\([^"]*\)".*/\1/p' "$STUDIO_DIR/hugmesh_studio/__init__.py" | head -n 1)
MSI_NAME=hugmesh-studio-$VERSION-x64.msi

XVFB_PID=""
GUARDED=0

# ---- small helpers --------------------------------------------------------------------------
say()  { printf '==> %s\n' "$*" >&2; }
note() { printf '    %s\n' "$*" >&2; }
die()  { printf 'build-msi-wine.sh: error: %s\n' "$*" >&2; exit 1; }

on_error() {
  local rc=$1
  local line=$2
  # The first line only: for a here-document $BASH_COMMAND is the whole embedded script.
  local cmd=${BASH_COMMAND%%$'\n'*}
  printf 'build-msi-wine.sh: FAILED (exit %s) at line %s: %s\n' "$rc" "$line" "${cmd:0:160}" >&2
}
trap 'on_error $? $LINENO' ERR

cleanup() {
  # `wineserver -k` runs only WITH our prefix exported, and only once guard_prefix has
  # vetted it: bare, it would kill the servers of whatever default prefix is open.
  if [ "$GUARDED" = 1 ] && [ -f "$HUGMESH_WINE_PREFIX/$PREFIX_MARK" ]; then
    WINEPREFIX=$HUGMESH_WINE_PREFIX "$HUGMESH_WINESERVER" -k >/dev/null 2>&1 || true
  fi
  if [ -n "$XVFB_PID" ]; then
    kill "$XVFB_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

usage() {
  sed -n '2,/^set -Eeuo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
}

clone_tree() {  # hard links when they work (same filesystem), else a copy
  cp -al "$1/." "$2/" 2>/dev/null || cp -a "$1/." "$2/"
}

# ---- refuse to touch ~/.wine, before the first wine call --------------------------------------
guard_prefix() {
  local want default
  want=$(realpath -m -- "$HUGMESH_WINE_PREFIX")
  default=$(realpath -m -- "${HOME}/.wine")
  if [ "$want" = "$default" ]; then
    die "HUGMESH_WINE_PREFIX is your default Wine prefix ($default). This script installs Python, .NET and WiX into its prefix and will not touch yours. Pick another directory."
  fi
  case "$want" in
    "$default"/?*) die "HUGMESH_WINE_PREFIX ($want) is inside your default Wine prefix ($default)." ;;
  esac
  if [ -e "$want" ] && [ ! -f "$want/$PREFIX_MARK" ] && [ -n "$(ls -A "$want" 2>/dev/null)" ]; then
    die "$want exists, is not empty, and was not created by this script (no $PREFIX_MARK inside). Refusing to install into a Wine prefix that might be someone's. Point HUGMESH_WINE_PREFIX at a new directory."
  fi
  HUGMESH_WINE_PREFIX=$want
  # An ambient WINEPREFIX is ignored: ours is exported on every call.
  unset WINEPREFIX WINELOADER WINESERVER
  GUARDED=1
}

# ---- running things under Wine ----------------------------------------------------------------
# Every Wine call goes through wine_run. The environment is built with `env`, so HUGMESH_*
# variables in the caller's shell (HUGMESH_ROLES_LIB would point the frozen app at a
# checkout) cannot leak into a Windows process. WINE_TIMEOUT=<seconds> wine_run ... bounds it.
WINE_OVERRIDES='mshtml=,winemenubuilder.exe=d'
WINE_ENV_EXTRA=()   # NAME=value pairs a caller WANTS the Windows process to see; applied after the scrub
SCRUB=()
refresh_scrub() {
  SCRUB=()
  local name
  while IFS= read -r name; do
    SCRUB+=(-u "$name")
  done < <(compgen -e | grep '^HUGMESH_' || true)
}
wine_run() {
  # winemenubuilder.exe=d: otherwise installing an MSI that has a Start Menu shortcut makes
  # Wine write .desktop files and icons into the REAL ~/.local/share, outside the prefix.
  # QT_QPA_PLATFORM is dropped: an ambient `xcb` is wrong for a Windows Qt (the render step
  # sets its own, Windows-side).
  local bound=()
  if [ -n "${WINE_TIMEOUT:-}" ]; then
    bound=(timeout "$WINE_TIMEOUT")
  fi
  "${bound[@]}" env -u QT_QPA_PLATFORM "${SCRUB[@]}" "${WINE_ENV_EXTRA[@]}" \
    WINEPREFIX="$HUGMESH_WINE_PREFIX" WINEARCH=win64 WINEDEBUG="$HUGMESH_WINEDEBUG" \
    WINEDLLOVERRIDES="$WINE_OVERRIDES" \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 DOTNET_SYSTEM_GLOBALIZATION_PREDEFINED_CULTURES_ONLY=false \
    DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONUTF8=1 \
    "$HUGMESH_WINE" "$@"
}
wine_py() { wine_run "$PYEXE" "$@"; }
winepath_w() { wine_run winepath -w "$1" 2>/dev/null | tr -d '\r' | tail -n 1; }
wine_stop() { WINEPREFIX=$HUGMESH_WINE_PREFIX "$HUGMESH_WINESERVER" -k >/dev/null 2>&1 || true; }

start_xvfb() {
  if [ -n "$XVFB_PID" ]; then
    return 0
  fi
  command -v Xvfb >/dev/null 2>&1 || die "Xvfb is not installed. Wine wants a display even for its console programs; this script starts its own so nothing opens on yours."
  mkdir -p "$BUILD"
  local dispfile
  dispfile=$(mktemp "$BUILD/xvfb.XXXXXX")
  Xvfb -displayfd 3 -screen 0 1280x1024x24 -nolisten tcp 3>"$dispfile" >/dev/null 2>&1 &
  XVFB_PID=$!
  local i
  for i in $(seq 1 100); do
    [ -s "$dispfile" ] && break
    sleep 0.1
  done
  [ -s "$dispfile" ] || die "Xvfb did not start"
  DISPLAY=":$(head -n 1 "$dispfile")"
  export DISPLAY
  unset WAYLAND_DISPLAY
  rm -f "$dispfile"
}

# ---- downloads --------------------------------------------------------------------------------
# fetch URL DEST ALGO HASH: leaves DEST in place only if it hashes to HASH. A cached copy is
# re-hashed every time, so a truncated or tampered cache cannot be used.
fetch() {
  local url=$1
  local dest=$2
  local algo=$3
  local want=$4
  local got
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ]; then
    got=$("${algo}sum" "$dest" | cut -d' ' -f1)
    if [ "$got" = "$want" ]; then
      note "cached and verified: $(basename "$dest")"
      return 0
    fi
    note "cached $(basename "$dest") does not match its pin; downloading again"
    rm -f "$dest"
  fi
  note "downloading $url"
  curl --fail --silent --show-error --location --retry 3 --output "$dest.part" "$url"
  got=$("${algo}sum" "$dest.part" | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    rm -f "$dest.part"
    die "$url hashes to $algo:$got, expected $want. Not using it."
  fi
  mv "$dest.part" "$dest"
}

# unpack ZIP INTO SUBDIR STAMP: extract SUBDIR of ZIP (or all of it) into INTO, once per STAMP.
unpack() {
  local zip=$1
  local into=$2
  local subdir=$3
  local stamp=$4
  if [ -f "$into/.pinned" ] && [ "$(cat "$into/.pinned")" = "$stamp" ]; then
    return 0
  fi
  rm -rf "$into"
  mkdir -p "$into"
  python3 - "$zip" "$into" "$subdir" <<'PY'
import os, shutil, sys, tempfile, zipfile
zip_path, into, subdir = sys.argv[1:4]
with tempfile.TemporaryDirectory() as tmp:
    zipfile.ZipFile(zip_path).extractall(tmp)
    root = os.path.join(tmp, subdir) if subdir else tmp
    if not os.path.isdir(root):
        raise SystemExit("%s has no %s folder" % (zip_path, subdir))
    for name in os.listdir(root):
        src = os.path.join(root, name)
        dst = os.path.join(into, name)
        (shutil.copytree if os.path.isdir(src) else shutil.copy2)(src, dst)
PY
  printf '%s' "$stamp" > "$into/.pinned"
}

# ---- phases -----------------------------------------------------------------------------------
phase_fetch() {
  say "fetch: pinned downloads"
  fetch "$PYTHON_URL" "$DL/python-$PYTHON_VERSION-amd64.exe" sha256 "$PYTHON_SHA256"
  fetch "$DOTNET_URL" "$DL/dotnet-runtime-$DOTNET_VERSION-win-x64.zip" sha512 "$DOTNET_SHA512"
  fetch "$WIX_URL" "$DL/wix.$WIX_VERSION.nupkg" sha512 "$WIX_SHA512"
  fetch "$WIXUI_URL" "$DL/wixtoolset.ui.wixext.$WIX_VERSION.nupkg" sha512 "$WIXUI_SHA512"
}

py_version() {
  wine_py -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null | tr -d '\r' | tail -n 1 || true
}

phase_prefix() {
  say "prefix: private Wine prefix at $HUGMESH_WINE_PREFIX"
  command -v "$HUGMESH_WINE" >/dev/null 2>&1 || die "wine not found (set HUGMESH_WINE)"
  [ -f "$DL/python-$PYTHON_VERSION-amd64.exe" ] || die "run the fetch phase first"
  start_xvfb
  if [ ! -f "$HUGMESH_WINE_PREFIX/system.reg" ]; then
    mkdir -p "$HUGMESH_WINE_PREFIX"
    : > "$HUGMESH_WINE_PREFIX/$PREFIX_MARK"
    # mscoree,mshtml disabled ONLY for creation: otherwise Wine stops to offer to download
    # Mono and Gecko. After creation mscoree must be on, or Wine cannot load .NET images.
    WINE_OVERRIDES='mscoree,mshtml=,winemenubuilder.exe=d' wine_run wineboot --init >/dev/null 2>&1 || true
    WINEPREFIX=$HUGMESH_WINE_PREFIX "$HUGMESH_WINESERVER" -w
    [ -f "$HUGMESH_WINE_PREFIX/system.reg" ] || die "wineboot did not create a prefix"
  fi
  : > "$HUGMESH_WINE_PREFIX/$PREFIX_MARK"
  local drive_c=$HUGMESH_WINE_PREFIX/drive_c

  if [ "$(py_version)" != "$PYTHON_VERSION" ]; then
    say "installing Python $PYTHON_VERSION"
    wine_run "$DL/python-$PYTHON_VERSION-amd64.exe" /quiet InstallAllUsers=0 'TargetDir=C:\Python312' \
      Include_launcher=0 InstallLauncherAllUsers=0 Include_test=0 Include_doc=0 Include_tcltk=0 \
      Include_dev=0 AssociateFiles=0 Shortcuts=0 PrependPath=0 CompileAll=0 Include_pip=1 >/dev/null 2>&1 || true
    [ "$(py_version)" = "$PYTHON_VERSION" ] || die "Python $PYTHON_VERSION did not install under Wine (got '$(py_version)')"
  fi

  say "installing the locked Python packages (pip --require-hashes)"
  local lock
  lock=$(winepath_w "$WIX_SRC_DIR/windows-build-requirements.txt")
  wine_py -m pip install --require-hashes --only-binary=:all: --no-warn-script-location \
    --progress-bar off --quiet -r "$lock"
  check_no_drift

  install_icu_shim

  say "unpacking the .NET runtime, WiX $WIX_VERSION and its UI extension"
  unpack "$DL/dotnet-runtime-$DOTNET_VERSION-win-x64.zip" "$drive_c/dotnet" "" "$DOTNET_SHA512"
  unpack "$DL/wix.$WIX_VERSION.nupkg" "$drive_c/wix" "tools/net6.0/any" "$WIX_SHA512"
  unpack "$DL/wixtoolset.ui.wixext.$WIX_VERSION.nupkg" "$drive_c/wixext/ui" "wixext6" "$WIXUI_SHA512"
  local got
  got=$(wine_run 'C:\dotnet\dotnet.exe' "$WIX_DLL" --version 2>/dev/null | tr -d '\r' | tail -n 1 || true)
  case "$got" in
    "$WIX_VERSION"+*|"$WIX_VERSION") note "wix $got runs under Wine on .NET $DOTNET_VERSION" ;;
    *) die "wix did not report $WIX_VERSION under Wine (got '$got')" ;;
  esac
}

# What pip left installed must be exactly what the lock names: a stray package would change
# what PyInstaller finds without anything saying so.
check_no_drift() {
  local frozen
  local locked
  frozen=$(wine_py -m pip freeze 2>/dev/null | tr -d '\r' | grep '==' | grep -v '^pip==' | tr 'A-Z_' 'a-z-' | sort || true)
  locked=$(grep -E '^[A-Za-z0-9._-]+==' "$WIX_SRC_DIR/windows-build-requirements.txt" | sed 's/ *\\$//' | tr 'A-Z_' 'a-z-' | sort || true)
  if [ -z "$locked" ] || [ "$frozen" != "$locked" ]; then
    printf 'installed:\n%s\nlocked:\n%s\n' "$frozen" "$locked" >&2
    die "the Wine Python's packages differ from windows-build-requirements.txt. Delete $HUGMESH_WINE_PREFIX and run again."
  fi
}

# Candidate folders for Wine's own Tahoma replacement, most specific first. Wine ships it
# (LGPL) but WHERE depends on the distribution, hence a list and an override.
wine_fonts_candidates() {
  local wine_real
  wine_real=$(readlink -f "$(command -v "$HUGMESH_WINE")" 2>/dev/null || true)
  if [ -n "${HUGMESH_WINE_FONT_DIR:-}" ]; then
    printf '%s\n' "$HUGMESH_WINE_FONT_DIR"
  fi
  if [ -n "$wine_real" ]; then
    printf '%s\n' "$(dirname "$wine_real")/../share/wine/fonts"
  fi
  local d
  for d in /usr/share/wine/fonts /usr/share/wine*/wine/fonts /usr/lib/wine/fonts /usr/lib64/wine/fonts \
           /usr/local/share/wine/fonts /opt/wine*/share/wine/fonts; do
    printf '%s\n' "$d"
  done
}

# find_wine_fonts_dir DIR...: the first DIR holding both faces, else nothing and status 1.
find_wine_fonts_dir() {
  local d
  for d in "$@"; do
    if [ -f "$d/tahoma.ttf" ] && [ -f "$d/tahomabd.ttf" ]; then
      printf '%s' "$d"
      return 0
    fi
  done
  return 1
}

# The icon's letter is drawn with Wine's own Tahoma. A fresh prefix has none registered, so
# Qt falls back to a THIN SERIF 'S' (measured: 2063 white pixels, the bold sans mark has
# ~4800) in an icon that is meant to be bold and sans. Registering the faces in the Wine
# registry was tried first; it did not survive a first run reliably, so render_icon_wine.py
# loads the files directly. This only puts them in one place for it.
stage_ui_font() {
  local dir
  local candidates=()
  local line
  while IFS= read -r line; do
    candidates+=("$line")
  done < <(wine_fonts_candidates)
  dir=$(find_wine_fonts_dir "${candidates[@]}") \
    || die "cannot find Wine's tahoma.ttf and tahomabd.ttf (looked in: ${candidates[*]}). Install your distribution's Wine fonts package or set HUGMESH_WINE_FONT_DIR; without them the installer's icon is drawn with the wrong font."
  mkdir -p "$BUILD/fonts"
  local face
  for face in tahoma.ttf tahomabd.ttf; do
    cp -f "$dir/$face" "$BUILD/fonts/$face"
  done
  note "icon font: Wine's Tahoma from $dir"
}

# render_icon: run gen_icons.py, unchanged, through render_icon_wine.py (Qt's windows platform
# and Wine's Tahoma) from the current directory (studio/). The font folder reaches the Windows
# process through WINE_ENV_EXTRA, set INSIDE a subshell: bash does not apply an array
# assignment written as a command prefix (`A=(x) cmd` hands cmd the string "(x)"), which is how
# the first version of this passed the Windows process nothing.
render_icon() {
  (
    WINE_ENV_EXTRA=(HUGMESH_ICON_FONT_DIR="$(winepath_w "$BUILD/fonts")")
    wine_py "$(winepath_w "$WIX_SRC_DIR/render_icon_wine.py")" --out build/icons
  ) 2>&1 | tee "$LOGS/gen_icons.log" | sed 's/^/    /' >&2
}

# Wine has no icuuc.dll, which PySide6's Qt6Core.dll imports. See wine_icu_shim.py. It goes in
# the prefix's system32, never beside Qt6Core.dll, so PyInstaller does not bundle it.
install_icu_shim() {
  local qt=$HUGMESH_WINE_PREFIX/drive_c/Python312/Lib/site-packages/PySide6/Qt6Core.dll
  local out=$HUGMESH_WINE_PREFIX/drive_c/windows/system32/icuuc.dll
  [ -f "$qt" ] || die "Qt6Core.dll is not where the locked PySide6 puts it: $qt"
  local tmp
  tmp=$(mktemp "$BUILD/icuuc.XXXXXX")
  python3 "$WIX_SRC_DIR/wine_icu_shim.py" --qt-dll "$qt" --out "$tmp" >/dev/null
  if ! cmp -s "$tmp" "$out" 2>/dev/null; then
    cp "$tmp" "$out"
    note "installed the icuuc.dll forwarder into the prefix's system32"
  fi
  rm -f "$tmp"
  wine_py -c 'import PySide6.QtCore as q; print(q.qVersion())' >/dev/null 2>&1 \
    || die "PySide6.QtCore does not import under Wine even with the ICU forwarder"
}

copy_checkout() {
  cd "$HUGMESH_MSI_WORKDIR"
  rm -rf "$SRC"
  mkdir -p "$SRC" "$LOGS"
  # What a CI checkout would contain: tracked files plus new files git does not ignore. A
  # git-ignored file is therefore NOT copied, which is how the missing-spec defect shows up
  # here as it does in CI.
  if [ "$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null || true)" = "$REPO_DIR" ]; then
    (cd "$REPO_DIR" && git ls-files -z --cached --others --exclude-standard -- studio LICENSE \
      | tar --null --ignore-failed-read -T - -cf - 2>/dev/null) | tar -xf - -C "$SRC"
  else
    tar -C "$REPO_DIR" --exclude='__pycache__' --exclude='studio/build' --exclude='studio/dist' \
      -cf - studio LICENSE | tar -xf - -C "$SRC"
  fi
  [ -f "$SRC/studio/packaging/hugmesh-studio.spec" ] \
    || die "packaging/hugmesh-studio.spec is not in the checkout copy. Is it git-ignored? Try: git check-ignore -v studio/packaging/hugmesh-studio.spec"
}

# The package-data files the wheel declares, as paths relative to studio/, read by the
# Windows Python (3.12 has tomllib; the build machine's python3 may not).
expected_data_files() {
  (cd "$SRC/studio" && wine_py -c '
import glob, os, tomllib
table = tomllib.load(open("pyproject.toml", "rb"))["tool"]["setuptools"]["package-data"]
for package, patterns in sorted(table.items()):
    for pattern in patterns:
        for hit in sorted(glob.glob(os.path.join(*package.split("."), pattern))):
            print(hit.replace(os.sep, "/"))
' 2>/dev/null | tr -d '\r' | grep -v '^wineserver' || true)
}

# tree_check APP: the files the frozen app needs exist in the onedir, and the ones that must
# not be there are not. Prints one line per failure; returns 1 if any.
tree_check() {
  local app=$1
  local bad=0
  local rel
  local data
  data=$(expected_data_files)
  if [ -z "$data" ]; then
    echo "could not read package-data from pyproject.toml"
    return 1
  fi
  while IFS= read -r rel; do
    [ -f "$app/_internal/$rel" ] || { echo "MISSING package data: _internal/$rel"; bad=1; }
  done <<<"$data"
  # tzdata: core/timezones.py silently falls back to 50 zones without it.
  [ -f "$app/_internal/tzdata/zoneinfo/Europe/Berlin" ] || { echo "MISSING tzdata zone files"; bad=1; }
  [ -f "$app/_internal/tzdata/zones" ] || { echo "MISSING tzdata/zones index"; bad=1; }
  [ -f "$app/_internal/PySide6/plugins/platforms/qwindows.dll" ] || { echo "MISSING Qt platform plugin qwindows.dll"; bad=1; }
  [ -n "$(find "$app" -iname 'msvcp140.dll' -print -quit)" ] || { echo "MISSING msvcp140.dll (the C++ runtime Qt links)"; bad=1; }
  [ -f "$app/hugmesh-studio.exe" ] || { echo "MISSING hugmesh-studio.exe"; bad=1; }
  # Must NOT ship: the Wine-only ICU forwarder, and a second Qt binding (PyQt6 is GPL).
  [ -z "$(find "$app" -iname 'icuuc.dll' -print -quit)" ] || { echo "UNWANTED icuuc.dll (the Wine build shim) is in the bundle"; bad=1; }
  [ -z "$(find "$app" -ipath '*pyqt*' -print -quit)" ] || { echo "UNWANTED PyQt files in the bundle (licence)"; bad=1; }
  return "$bad"
}

phase_freeze() {
  say "freeze: PyInstaller under Wine"
  [ -f "$HUGMESH_WINE_PREFIX/drive_c/Python312/python.exe" ] || die "no Wine Python yet; run the prefix phase first"
  start_xvfb
  copy_checkout
  cd "$SRC/studio"

  say "rendering the application icon (gen_icons.py as written, via render_icon_wine.py: Qt's windows platform, because offscreen draws the S as an empty box, and Wine's Tahoma)"
  stage_ui_font
  render_icon
  [ -f build/icons/hugmesh-studio.ico ] || die "gen_icons.py did not write build/icons/hugmesh-studio.ico"
  wine_py -c '
import sys
from PIL import Image
im = Image.open("build/icons/icon-256.png").convert("RGBA")
w, h = im.size
px = im.load()
white = sum(1 for x in range(int(w * .3), int(w * .7)) for y in range(int(h * .3), int(h * .7))
            if px[x, y][3] > 200 and min(px[x, y][:3]) > 200)
print("white pixels in the icon centre:", white)
sys.exit(0 if white > 3000 else 1)
' 2>/dev/null | tr -d '\r' | grep -v '^wineserver' | sed 's/^/    /' >&2 \
    || die "the rendered icon's letter is missing or not bold (an empty box is 0 pixels, a thin serif ~2000, the bold sans mark ~4800); not freezing an installer with the wrong icon. See render_icon_wine.py."

  say "pyinstaller --noconfirm --clean packaging/hugmesh-studio.spec"
  wine_run cmd /c 'set HUGMESH_STUDIO_ICON=build/icons/hugmesh-studio.ico&& C:\Python312\python.exe -m PyInstaller --noconfirm --clean packaging/hugmesh-studio.spec' \
    2>&1 | tee "$LOGS/pyinstaller.log" | grep -E 'ERROR|Build complete' >&2 || true
  [ -f "$DIST_APP/hugmesh-studio.exe" ] || die "PyInstaller produced no dist/hugmesh-studio/hugmesh-studio.exe (see $LOGS/pyinstaller.log)"
  note "$(find "$DIST_APP" -type f | wc -l) files, $(du -sh "$DIST_APP" | cut -f1)"

  say "smoke: the frozen tree"
  tree_check "$DIST_APP" >&2 || die "the frozen tree is incomplete (above)"
  note "all package data, tzdata, Qt platform plugin and C++ runtime present; no ICU shim, no PyQt"

  say "smoke: hugmesh-studio.exe --print-specs"
  smoke_cli "$DIST_APP" >&2 || die "the frozen exe's --print-specs smoke test failed (above)"
  smoke_gui "$DIST_APP" >&2 || die "the frozen exe's window did not appear (above)"
}

# smoke_cli APP: run APP's exe from a directory with no checkout near it, HUGMESH_* scrubbed,
# stdout redirected to a file the way the workflow does it, and require non-empty JSON that
# equals what the same command prints when run from source under the same Windows Python.
smoke_cli() {
  local app=$1
  local work=$BUILD/smoke
  rm -rf "$work"
  mkdir -p "$work/cwd" "$work/app"
  clone_tree "$app" "$work/app"
  local exe studio
  exe=$(winepath_w "$work/app/hugmesh-studio.exe")
  studio=$(winepath_w "$SRC/studio")
  # HUGMESH_BUILD_JOBS: the default job count is derived from this machine's free memory at
  # that instant, so unpinned it would differ between two runs for no reason that matters.
  printf '@echo off\r\nset HUGMESH_BUILD_JOBS=2\r\n"%s" --print-specs > specs.json\r\n' "$exe" > "$work/cwd/run.cmd"
  printf '@echo off\r\nset HUGMESH_BUILD_JOBS=2\r\nset PYTHONPATH=%s\r\n"%s" -m hugmesh_studio --print-specs > source-specs.json\r\n' \
    "$studio" "$PYEXE" > "$work/cwd/run-source.cmd"
  local rc=0
  (cd "$work/cwd" && WINE_TIMEOUT=120 wine_run cmd /c run.cmd >"$work/cli.out" 2>"$work/cli.err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    # 124 is `timeout`: a bundle that cannot import makes PyInstaller's bootloader show a modal
    # error dialog that nobody answers, so a missing file looks like a hang, not an exit code.
    wine_stop
    echo "the exe exited $rc (124 = hung, which is what a bundle that cannot import looks like)"
    return 1
  fi
  [ -s "$work/cwd/specs.json" ] || { echo "specs.json is empty: --print-specs printed nothing"; return 1; }
  (cd "$work/cwd" && WINE_TIMEOUT=120 wine_run cmd /c run-source.cmd >/dev/null 2>&1) || true
  python3 - "$work/cwd/specs.json" "$work/cwd/source-specs.json" <<'PY'
import json, sys
def first_json_line(path):
    with open(path, "rb") as fh:
        lines = [l for l in fh.read().decode("utf-8").splitlines() if l.strip()]
    if not lines:
        raise ValueError("%s has no lines" % path)
    return json.loads(lines[0])
try:
    frozen = first_json_line(sys.argv[1])
except ValueError as exc:
    print("the frozen exe's output is not JSON: %s" % exc)
    raise SystemExit(1)
if not isinstance(frozen, dict) or not frozen:
    print("the frozen exe's first line is not a non-empty JSON object")
    raise SystemExit(1)
try:
    source = first_json_line(sys.argv[2])
except (OSError, ValueError):
    print("the from-source run printed nothing, so there is nothing to compare the frozen output with")
    raise SystemExit(1)
if frozen != source:
    print("frozen and from-source --print-specs differ in: %s"
          % ", ".join(sorted(k for k in set(frozen) | set(source) if frozen.get(k) != source.get(k))))
    raise SystemExit(1)
print("frozen --print-specs == from-source --print-specs (%d keys, non-empty JSON)" % len(frozen))
PY
}

# smoke_gui APP: start the frozen GUI on the private display and wait for its window.
smoke_gui() {
  local app=$1
  case "$HUGMESH_GUI_SMOKE" in
    0) note "GUI smoke skipped (HUGMESH_GUI_SMOKE=0)"; return 0 ;;
    auto|1) ;;
    *) die "HUGMESH_GUI_SMOKE must be auto, 1 or 0" ;;
  esac
  if ! command -v xdotool >/dev/null 2>&1; then
    [ "$HUGMESH_GUI_SMOKE" = 1 ] && die "HUGMESH_GUI_SMOKE=1 but xdotool is not installed"
    note "GUI smoke skipped: xdotool is not installed"
    return 0
  fi
  start_xvfb
  say "smoke: start the frozen GUI and wait for its window"
  local work=$BUILD/smoke-gui
  rm -rf "$work"
  mkdir -p "$work/app" "$work/cwd"
  clone_tree "$app" "$work/app"
  local exe
  exe=$(winepath_w "$work/app/hugmesh-studio.exe")
  # Its state (instance socket, session records) goes in the prefix, not a profile.
  (
    cd "$work/cwd"
    WINE_ENV_EXTRA=(HUGMESH_STUDIO_STATE_DIR='C:\hugmesh-smoke-state')
    wine_run "$exe" >"$work/gui.out" 2>"$work/gui.err" &
  )
  local waited=0
  local found=""
  while [ "$waited" -lt 90 ]; do
    sleep 2
    waited=$((waited + 2))
    found=$(xdotool search --onlyvisible --name 'HugMesh Image Studio' 2>/dev/null | head -n 1 || true)
    [ -n "$found" ] && break
  done
  if [ -z "$found" ]; then
    wine_stop
    echo "no window titled 'HugMesh Image Studio' after ${waited}s (a bundle that cannot import hangs on PyInstaller's error dialog)"
    return 1
  fi
  echo "window up after ${waited}s: $(xdotool getwindowname "$found" 2>/dev/null) $(xdotool getwindowgeometry "$found" 2>/dev/null | tr '\n' ' ')"
  if command -v import >/dev/null 2>&1; then
    mkdir -p "$HUGMESH_DIST_DIR"
    sleep 3
    if import -window root "$HUGMESH_DIST_DIR/frozen-gui-under-wine.png" 2>/dev/null; then
      echo "screenshot: $HUGMESH_DIST_DIR/frozen-gui-under-wine.png"
    fi
  fi
  wine_stop
  return 0
}

# build_msi APPDIR OUT.msi: wix build, the way the workflow does, with what had to differ.
build_msi() {
  local appdir=$1
  local out=$2
  mkdir -p "$(dirname "$out")" "$SRC/studio/build" "$LOGS"
  (cd "$SRC/studio" && wine_py packaging/wix/make_license_rtf.py --in ../LICENSE --out build/License.rtf 2>/dev/null \
    | tr -d '\r' | grep -v '^wineserver' | sed 's/^/    /' >&2)
  local appwin outwin
  appwin=$(winepath_w "$appdir")
  outwin=$(winepath_w "$out")
  rm -f "$out"
  (cd "$SRC/studio" && wine_run 'C:\dotnet\dotnet.exe' "$WIX_DLL" build -arch x64 \
      -dcl mszip \
      -define "Version=$VERSION" -define "IconFile=build/icons/hugmesh-studio.ico" \
      -define "LicenseFile=build/License.rtf" -define "AppDir=$appwin" \
      -ext "$WIXUI_DLL" -pdbtype none \
      -out "$outwin" packaging/wix/Package.wxs packaging/wix/Files.wxs) 2>&1 | tee -a "$LOGS/wix.log" | grep -v '^wineserver' >&2
  [ -s "$out" ]
}

phase_msi() {
  say "msi: wix build"
  [ -f "$DIST_APP/hugmesh-studio.exe" ] || die "no frozen app at $DIST_APP; run the freeze phase first"
  start_xvfb
  mkdir -p "$LOGS" "$HUGMESH_DIST_DIR"
  # -dcl mszip: Wine's cabinet.dll cannot do LZX (WiX's default), says "compression 1203 not
  # supported, defaulting to none", and then fails outright on a cabinet that holds two
  # files with the same content (the frozen tree has dozens). MSZIP it can do.
  build_msi "$DIST_APP" "$BUILD/out/$MSI_NAME" || die "wix build failed (above, and $LOGS/wix.log)"
  cp -f "$BUILD/out/$MSI_NAME" "$HUGMESH_DIST_DIR/$MSI_NAME"
  (cd "$HUGMESH_DIST_DIR" && sha256sum "$MSI_NAME" > "$MSI_NAME.sha256")
  note "$HUGMESH_DIST_DIR/$MSI_NAME  $(stat -c %s "$HUGMESH_DIST_DIR/$MSI_NAME") bytes"
  note "$(cat "$HUGMESH_DIST_DIR/$MSI_NAME.sha256")"
}

# export_msi MSI DIR: msiinfo + msiextract in a throwaway container, results owned by us.
export_msi() {
  local msi=$1
  local dir=$2
  command -v "$HUGMESH_DOCKER" >/dev/null 2>&1 || die "docker not found (set HUGMESH_DOCKER); the verify phase reads the MSI with msitools in a container"
  rm -rf "$dir"
  mkdir -p "$dir/tables" "$dir/extract" "$LOGS"
  "$HUGMESH_DOCKER" run --rm --network host \
    -v "$(dirname "$msi"):/in:ro" -v "$dir:/out" \
    -e "MSI=/in/$(basename "$msi")" -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
    "$MSITOOLS_IMAGE" bash -ec '
      # Whatever happens, hand /out back to the user who ran this: files left owned by root
      # cannot be deleted without sudo.
      trap "chown -R \"$HOST_UID:$HOST_GID\" /out" EXIT
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq >/dev/null
      apt-get install -y -qq --no-install-recommends msitools >/dev/null
      for t in Property File Component Directory Feature FeatureComponents Shortcut Icon Media Upgrade Registry RemoveFile Control; do
        msiinfo export "$MSI" "$t" > "/out/tables/$t.idt" || : > "/out/tables/$t.idt"
      done
      msiinfo suminfo "$MSI" > /out/tables/suminfo.txt
      msiinfo streams "$MSI" > /out/tables/streams.txt
      msiinfo extract "$MSI" Icon.AppIcon > /out/tables/Icon.AppIcon
      msiextract -C /out/extract "$MSI" > /out/extract.log
    ' >"$LOGS/msitools.log" 2>&1 || { tail -n 20 "$LOGS/msitools.log" >&2; return 1; }
}

run_verifier() {
  local dir=$1
  local want_version=$2
  python3 "$WIX_SRC_DIR/verify_msi.py" --tables "$dir/tables" --extract "$dir/extract" \
    --dist "$DIST_APP" --version "$want_version" --package-wxs "$WIX_SRC_DIR/Package.wxs" \
    --icon "$SRC/studio/build/icons/hugmesh-studio.ico" --license "$SRC/LICENSE"
}

phase_verify() {
  say "verify: read the MSI with msitools and compare it with the frozen tree"
  local msi=$HUGMESH_DIST_DIR/$MSI_NAME
  [ -f "$msi" ] || die "no $msi; run the msi phase first"
  (cd "$HUGMESH_DIST_DIR" && sha256sum -c "$MSI_NAME.sha256" >/dev/null) || die "$MSI_NAME does not match its .sha256 file"
  export_msi "$msi" "$BUILD/msitools" || die "msitools export failed"
  run_verifier "$BUILD/msitools" "$VERSION" | sed 's/^/    /' >&2 || die "the MSI does not match what it was built from (above)"
}

phase_install_test() {
  say "install-test: Wine's own msiexec installs, runs and removes the MSI (not the real Windows Installer)"
  local msi=$HUGMESH_DIST_DIR/$MSI_NAME
  [ -f "$msi" ] || die "no $msi; run the msi phase first"
  start_xvfb
  local localapp unix_local base msi_win
  localapp=$(wine_run cmd /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r' | grep -v '^wineserver' | tail -n 1 || true)
  unix_local=$(wine_run winepath -u "$localapp" 2>/dev/null | tr -d '\r' | tail -n 1 || true)
  [ -d "$unix_local" ] || die "cannot find the Wine user's LocalAppData ($localapp)"
  base=$unix_local/HugMesh
  msi_win=$(winepath_w "$msi")
  wine_run msiexec /x "$msi_win" /qn >/dev/null 2>&1 || true        # a clean start; harmless if absent
  local existed=0
  [ -d "$base" ] && existed=1

  wine_run msiexec /i "$msi_win" /qn >/dev/null 2>&1 || die "msiexec /i failed"
  local installed expected
  installed=$(find "$base/Image Studio" -type f 2>/dev/null | wc -l)
  expected=$(find "$DIST_APP" -type f | wc -l)
  [ "$installed" -eq "$expected" ] || die "installed $installed files, the frozen tree has $expected"
  note "installed $installed files into %LOCALAPPDATA%\\HugMesh\\Image Studio"
  [ -n "$(find "$HUGMESH_WINE_PREFIX/drive_c/users" -iname 'HugMesh Image Studio.lnk' -print -quit 2>/dev/null)" ] \
    || die "no Start Menu shortcut was created"
  wine_run reg query 'HKCU\Software\HugMesh\ImageStudio' /v installed >/dev/null 2>&1 \
    || die "the HKCU\\Software\\HugMesh\\ImageStudio value was not written"
  note "Start Menu shortcut and HKCU key present"

  local work=$BUILD/install-test
  rm -rf "$work"
  mkdir -p "$work"
  printf '@echo off\r\nset HUGMESH_BUILD_JOBS=2\r\n"%s\\Image Studio\\hugmesh-studio.exe" --print-specs > specs.json\r\n' \
    "$(winepath_w "$base")" > "$work/run.cmd"
  (cd "$work" && WINE_TIMEOUT=120 wine_run cmd /c run.cmd >/dev/null 2>&1) || { wine_stop; die "the INSTALLED exe failed to run"; }
  [ -s "$work/specs.json" ] || die "the INSTALLED exe printed nothing for --print-specs"
  python3 - "$work/specs.json" "$BUILD/smoke/cwd/specs.json" <<'PY'
import json, sys
def load(path):
    return json.loads([l for l in open(path, "rb").read().decode().splitlines() if l.strip()][0])
installed = load(sys.argv[1])
try:
    frozen = load(sys.argv[2])
except (OSError, IndexError):
    print("    the installed exe printed %d keys (no earlier smoke output to compare with)" % len(installed))
    raise SystemExit(0)
if installed != frozen:
    raise SystemExit("the INSTALLED exe's output differs from the frozen tree's")
print("    the installed exe prints the same specs as the frozen tree (%d keys)" % len(installed))
PY

  wine_run msiexec /x "$msi_win" /qn >/dev/null 2>&1 || die "msiexec /x failed"
  [ ! -e "$base/Image Studio" ] || die "uninstall left $base/Image Studio behind"
  [ -z "$(find "$HUGMESH_WINE_PREFIX/drive_c/users" -iname 'HugMesh Image Studio.lnk' -print -quit 2>/dev/null)" ] \
    || die "uninstall left the Start Menu shortcut behind"
  if wine_run reg query 'HKCU\Software\HugMesh\ImageStudio' >/dev/null 2>&1; then
    die "uninstall left the HKCU value behind"
  fi
  # %LOCALAPPDATA%\HugMesh (the company folder) has no component of its own, so nothing removes
  # it and Wine's installer leaves it empty. A RemoveFolder row for it was tried and changed
  # nothing under Wine (Wine's installer deletes folders before the files), so the package is
  # left as it was and the folder is reported, not asserted. Whether Windows Installer removes
  # it is unverified.
  if [ "$existed" = 0 ] && [ -e "$base" ]; then
    note "left behind (as before this change): an empty %LOCALAPPDATA%\\HugMesh folder; see the README"
  fi
  note "uninstalled: the install folder, Start Menu shortcut and registry value are gone"
}

# expect_red NAME COMMAND...: the command must FAIL. The whole point of a smoke test is that
# it can, so this runs each one against a bundle broken on purpose.
expect_red() {
  local name=$1
  shift
  local out
  if out=$("$@" 2>&1); then
    printf '%s\n' "$out" >&2
    die "SELFTEST FAILED: '$name' passed on a broken input, so it cannot detect that breakage"
  fi
  note "red as it should be: $name  ($(printf '%s' "$out" | head -n 1 | cut -c1-100))"
}

mutant() {  # mutant NAME RELPATH...: a copy of the onedir missing the named files
  local name=$1
  shift
  local dir=$BUILD/mutants/$name
  rm -rf "$dir"
  mkdir -p "$dir"
  clone_tree "$DIST_APP" "$dir"
  local rel
  for rel in "$@"; do
    rm -f "$dir/$rel"
  done
  printf '%s' "$dir"
}

phase_selftest() {
  say "selftest: break things on purpose; every check below must turn red"
  [ -f "$DIST_APP/hugmesh-studio.exe" ] || die "no frozen app; run the freeze phase first"
  start_xvfb
  local good=$HUGMESH_DIST_DIR/$MSI_NAME
  [ -f "$good" ] || die "no $good; run the msi phase first"
  rm -rf "$BUILD/mutants"
  local rel
  # A check that is red on EVERYTHING proves nothing, so the intact inputs go first.
  say "selftest controls: the intact bundle and MSI must pass"
  tree_check "$DIST_APP" >/dev/null || die "SELFTEST CONTROL FAILED: tree_check rejects the intact bundle"
  smoke_cli "$DIST_APP" >/dev/null || die "SELFTEST CONTROL FAILED: the --print-specs smoke rejects the intact bundle"
  export_msi "$good" "$BUILD/selftest-good" || die "msitools export failed"
  run_verifier "$BUILD/selftest-good" "$VERSION" >/dev/null || die "SELFTEST CONTROL FAILED: the verifier rejects the intact MSI"
  note "controls pass"
  say "selftest: now the broken inputs"
  expect_red "tree check without hugmesh-studio.exe" tree_check "$(mutant noexe hugmesh-studio.exe)"
  while IFS= read -r rel; do
    expect_red "tree check without $rel" tree_check "$(mutant "nodata-$(basename "$rel")" "_internal/$rel")"
  done < <(expected_data_files)
  expect_red "tree check without tzdata" tree_check "$(mutant notz _internal/tzdata/zones)"
  expect_red "--print-specs smoke without _roles-lib.sh" smoke_cli "$(mutant noroles _internal/hugmesh_studio/core/_roles-lib.sh)"
  if command -v xdotool >/dev/null 2>&1 && [ "$HUGMESH_GUI_SMOKE" != 0 ]; then
    expect_red "GUI smoke without progress-tables.json" smoke_gui "$(mutant noprogress _internal/hugmesh_studio/core/progress-tables.json)"
  else
    note "GUI selftest skipped (needs xdotool)"
  fi
  expect_red "verifier given the wrong version (9.9.9)" run_verifier "$BUILD/selftest-good" 9.9.9
  local bad_app
  bad_app=$(mutant mutant-msi hugmesh-studio.exe)
  build_msi "$bad_app" "$BUILD/selftest-bad/$MSI_NAME" >/dev/null 2>&1 || die "could not build the exe-less MSI"
  export_msi "$BUILD/selftest-bad/$MSI_NAME" "$BUILD/selftest-bad-export" || die "msitools export failed"
  expect_red "verifier on an MSI with no hugmesh-studio.exe" run_verifier "$BUILD/selftest-bad-export" "$VERSION"
  say "selftest: every deliberately broken input was caught"
}

phase_summary() {
  say "artifacts"
  local f
  for f in "$HUGMESH_DIST_DIR/$MSI_NAME" "$HUGMESH_DIST_DIR/$MSI_NAME.sha256"; do
    if [ -f "$f" ]; then
      printf '    %s  %s bytes\n' "$f" "$(stat -c %s "$f")" >&2
    fi
  done
  if [ -f "$HUGMESH_DIST_DIR/$MSI_NAME.sha256" ]; then
    printf '    sha256: %s\n' "$(cut -d' ' -f1 "$HUGMESH_DIST_DIR/$MSI_NAME.sha256")" >&2
  fi
  printf '    logs: %s\n' "$LOGS" >&2
}

# ---- main -------------------------------------------------------------------------------------
main() {
  local phases=("$@")
  if [ "${#phases[@]}" -eq 0 ]; then
    phases=(fetch prefix freeze msi verify install-test)
  fi
  local p
  for p in "${phases[@]}"; do
    case "$p" in
      -h|--help|help) usage; exit 0 ;;
      fetch|prefix|freeze|msi|verify|install-test|selftest) ;;
      *) die "unknown phase '$p' (fetch prefix freeze msi verify install-test selftest)" ;;
    esac
  done
  [ -n "$VERSION" ] || die "could not read __version__ from $STUDIO_DIR/hugmesh_studio/__init__.py"
  guard_prefix
  mkdir -p "$HUGMESH_MSI_WORKDIR" "$LOGS" "$BUILD/tmp"
  # Scratch (the unzip of the .NET runtime is ~70 MB) stays with the build, not in /tmp,
  # which on many machines is a small root filesystem that other programs need.
  export TMPDIR=$BUILD/tmp
  exec 9>"$HUGMESH_MSI_WORKDIR/.lock"
  flock -n 9 || die "another build-msi-wine.sh is using $HUGMESH_MSI_WORKDIR"
  say "HugMesh Image Studio $VERSION -> $MSI_NAME (prefix $HUGMESH_WINE_PREFIX)"
  refresh_scrub
  for p in "${phases[@]}"; do
    case "$p" in
      fetch) phase_fetch ;;
      prefix) phase_prefix ;;
      freeze) phase_freeze ;;
      msi) phase_msi ;;
      verify) phase_verify ;;
      install-test) phase_install_test ;;
      selftest) phase_selftest ;;
    esac
  done
  phase_summary
}

# Sourcing this file (the unit tests do) defines the functions and runs nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi

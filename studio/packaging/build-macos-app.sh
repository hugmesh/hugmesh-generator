#!/usr/bin/env bash
# build-macos-app.sh - build "HugMesh Image Studio.app" and
# hugmesh-studio-<version>-macos-<arch>.dmg on a Mac, from a checkout, with one command.
#
#   studio/packaging/build-macos-app.sh                         # every phase
#   studio/packaging/build-macos-app.sh --python .venv/bin/python --gui-smoke
#
# The SAME script runs in three places, so what a pull request proves is what a release
# ships: the `macos` job of .github/workflows/studio-tests.yml (every Studio pull
# request, Apple silicon and Intel), the `macos` job of studio-release.yml, and a
# developer's Mac.
#
#   icons    gen_icons.py --iconset, then iconutil      ->  build/icons/hugmesh-studio.icns
#   freeze   PyInstaller, packaging/hugmesh-studio.spec  ->  dist/HugMesh Image Studio.app
#   check    check_macos_bundle.py (Info.plist, Mach-O arch, Qt cocoa plugin, package
#            data) and `codesign --verify --deep --strict` of the ad-hoc signature
#   smoke    the frozen executable under FINDER'S environment: --print-specs, then
#            --self-check against the generator checkout (see SMOKE below)
#   gui      with --gui-smoke only: start the app for real (the cocoa platform plugin,
#            not offscreen), insist it is still running after 20 s, screenshot it
#   dmg      hdiutil UDZO image holding the .app and an /Applications link, its
#            .sha256, then attach it read-only and check the .app inside
#
# SMOKE runs with `env -i HOME=… PATH=/usr/bin:/bin:/usr/sbin:/sbin`, which is the
# environment launchd gives an app opened from Finder: no Homebrew, no Docker, no
# GNU tools on PATH. The Studio's own startup hook (core/macos_host.py) is what puts
# them back, and this is the step that proves it does.
#
# THIS SCRIPT RUNS UNDER macOS's OWN /bin/bash, which is 3.2: no associative arrays,
# no ${x,,}, no mapfile, and no "${array[@]}" of an empty array under set -u.
#
# UNSIGNED. PyInstaller signs the bundle ad hoc (Apple silicon refuses to run an
# unsigned executable at all). A Developer ID signature, notarization and stapling need
# the operator's Apple account; docs/STUDIO-INSTALLERS.md ("macOS") has the commands.
#
# OPTIONS
#   --python PY         the interpreter that has macos-build-requirements.txt installed
#                       (default: python3)
#   --version V         the version the bundle must carry (default: __version__)
#   --arch ARCH         arm64 or x86_64 (default: uname -m)
#   --dist DIR          where the .app, .dmg and .sha256 land (default: studio/dist)
#   --generator-dir D   the checkout --self-check reads (default: this repository)
#   --gui-smoke         also run the gui phase (opens a window: CI, or on purpose)
#   --no-dmg            stop after the smoke phases
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
STUDIO_DIR=$(dirname "$SCRIPT_DIR")
REPO_DIR=$(dirname "$STUDIO_DIR")
APP_NAME="HugMesh Image Studio"
EXE_NAME="hugmesh-studio"
# launchd's PATH for a GUI app: what a double-clicked .app starts with.
FINDER_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

die() { echo "build-macos-app.sh: $*" >&2; exit 1; }
say() { echo "==> $*"; }

usage() {
	sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

# The .dmg's file name. The release workflow, the docs and the site parse it.
dmg_name() {
	echo "hugmesh-studio-$1-macos-$2.dmg"
}

studio_version() {
	sed -n 's/^__version__ = "\([^"]*\)".*/\1/p' "$STUDIO_DIR/hugmesh_studio/__init__.py"
}

require_macos() {
	local sys
	sys=$(uname -s)
	if [ "$sys" != "Darwin" ]; then
		die "this builds the macOS app and needs a Mac (uname -s says $sys). On Linux the" \
			"same spec builds the tarball: pyinstaller packaging/hugmesh-studio.spec"
	fi
	local tool
	for tool in iconutil codesign hdiutil ditto; do
		command -v "$tool" >/dev/null 2>&1 || die "$tool is missing (it ships with macOS)"
	done
}

phase_icons() {
	say "icons"
	rm -rf "$STUDIO_DIR/build/icons"
	(cd "$STUDIO_DIR" && QT_QPA_PLATFORM=offscreen "$PY" packaging/gen_icons.py \
		--out build/icons --iconset)
	iconutil -c icns -o "$STUDIO_DIR/build/icons/hugmesh-studio.icns" \
		"$STUDIO_DIR/build/icons/hugmesh-studio.iconset"
	[ -s "$STUDIO_DIR/build/icons/hugmesh-studio.icns" ] || die "iconutil wrote no .icns"
}

phase_freeze() {
	say "freeze"
	(cd "$STUDIO_DIR" && HUGMESH_STUDIO_ICON=build/icons/hugmesh-studio.icns \
		"$PY" -m PyInstaller --noconfirm --clean packaging/hugmesh-studio.spec)
	[ -d "$APP" ] || die "PyInstaller did not write $APP"
	if [ "$DIST" != "$STUDIO_DIR/dist" ]; then
		rm -rf "$DIST/$APP_NAME.app"
		ditto "$STUDIO_DIR/dist/$APP_NAME.app" "$DIST/$APP_NAME.app"
	fi
}

phase_check() {
	say "check"
	"$PY" "$SCRIPT_DIR/check_macos_bundle.py" "$APP" --version "$VERSION" --arch "$ARCH"
	codesign --verify --deep --strict --verbose=2 "$APP"
	codesign --display --verbose=2 "$APP" 2>&1 | sed -n '1,8p'
}

# Run the frozen executable the way Finder would start it.
finder_env() {
	env -i HOME="$SMOKE_HOME" PATH="$FINDER_PATH" TMPDIR="${TMPDIR:-/tmp}" \
		LANG=en_US.UTF-8 "$@"
}

phase_smoke() {
	say "smoke (Finder's environment: PATH=$FINDER_PATH)"
	local exe="$APP/Contents/MacOS/$EXE_NAME"
	finder_env "$exe" --print-specs > "$WORK/specs.json"
	[ -s "$WORK/specs.json" ] || die "no output from --print-specs: the bundle is incomplete"
	head -c 300 "$WORK/specs.json"; echo
	local rc=0
	finder_env "$exe" --self-check --generator-dir "$GENERATOR_DIR" > "$WORK/self-check.txt" \
		2>&1 || rc=$?
	cat "$WORK/self-check.txt"
	[ "$rc" -eq 0 ] || die "--self-check failed (exit $rc) under Finder's environment"
}

phase_gui() {
	say "gui (a real window on the cocoa platform plugin)"
	local exe="$APP/Contents/MacOS/$EXE_NAME"
	finder_env QT_DEBUG_PLUGINS=1 "$exe" --generator-dir "$GENERATOR_DIR" \
		> "$WORK/gui.log" 2>&1 &
	local pid=$!
	sleep 20
	if ! kill -0 "$pid" 2>/dev/null; then
		cat "$WORK/gui.log"
		die "the app exited within 20 s of starting"
	fi
	# The libraries the running process has mapped: the cocoa plugin must be one of them
	# (offscreen or minimal would mean no window was ever possible).
	lsof -p "$pid" > "$WORK/gui-lsof.txt" 2>/dev/null || true
	screencapture -x "$DIST/gui-smoke-$ARCH.png" 2>/dev/null \
		|| echo "note: screencapture failed (no Screen Recording permission); not counted"
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	if ! grep -q "libqcocoa" "$WORK/gui-lsof.txt" "$WORK/gui.log"; then
		sed -n '1,40p' "$WORK/gui.log"
		die "the app did not load the cocoa platform plugin"
	fi
	echo "gui: still running after 20 s on the cocoa plugin"
}

make_dmg() {
	local stage="$WORK/dmg-stage" attempt
	rm -rf "$stage" && mkdir -p "$stage"
	ditto "$APP" "$stage/$APP_NAME.app"
	ln -s /Applications "$stage/Applications"
	rm -f "$DMG"
	# hdiutil create fails now and then on hosted runners with "Resource busy" while
	# Spotlight or XProtect still holds the freshly written tree; a retry clears it.
	for attempt in 1 2 3; do
		if hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -fs HFS+ \
			-format UDZO -ov "$DMG"; then
			return 0
		fi
		echo "hdiutil create failed (attempt $attempt); retrying in 10 s"
		sleep 10
	done
	die "hdiutil create failed three times"
}

phase_dmg() {
	say "dmg"
	make_dmg
	hdiutil verify "$DMG"
	(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
	cat "$DMG.sha256"
	local mnt="$WORK/mnt"
	mkdir -p "$mnt"
	hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$DMG" >/dev/null
	local ok=0
	if [ -x "$mnt/$APP_NAME.app/Contents/MacOS/$EXE_NAME" ] && [ -L "$mnt/Applications" ] \
		&& codesign --verify --deep --strict "$mnt/$APP_NAME.app"; then
		ok=1
	fi
	hdiutil detach "$mnt" >/dev/null || hdiutil detach -force "$mnt" >/dev/null || true
	[ "$ok" -eq 1 ] || die "the .dmg does not hold a runnable, validly signed $APP_NAME.app"
	echo "dmg: $DMG"
}

main() {
	PY=python3 VERSION="" ARCH="" DIST="$STUDIO_DIR/dist" GENERATOR_DIR="$REPO_DIR"
	local gui=0 dmg=1
	while [ $# -gt 0 ]; do
		case "$1" in
			--python) PY=${2:?--python needs a value}; shift 2 ;;
			--version) VERSION=${2:?--version needs a value}; shift 2 ;;
			--arch) ARCH=${2:?--arch needs a value}; shift 2 ;;
			--dist) DIST=${2:?--dist needs a value}; shift 2 ;;
			--generator-dir) GENERATOR_DIR=${2:?--generator-dir needs a value}; shift 2 ;;
			--gui-smoke) gui=1; shift ;;
			--no-dmg) dmg=0; shift ;;
			-h|--help) usage; return 0 ;;
			*) echo "build-macos-app.sh: unknown option $1 (see --help)" >&2; return 2 ;;
		esac
	done
	[ -n "$VERSION" ] || VERSION=$(studio_version)
	[ -n "$VERSION" ] || die "could not read __version__ from hugmesh_studio/__init__.py"
	[ -n "$ARCH" ] || ARCH=$(uname -m)
	case "$ARCH" in
		arm64|x86_64) ;;
		*) die "--arch must be arm64 or x86_64, not $ARCH" ;;
	esac
	require_macos
	mkdir -p "$DIST"
	DIST=$(cd "$DIST" && pwd -P)
	APP="$STUDIO_DIR/dist/$APP_NAME.app"
	DMG="$DIST/$(dmg_name "$VERSION" "$ARCH")"
	WORK=$(mktemp -d "${TMPDIR:-/tmp}/hugmesh-macos-build.XXXXXX")
	SMOKE_HOME="$WORK/home"
	mkdir -p "$SMOKE_HOME"
	echo "version $VERSION, arch $ARCH, python $("$PY" -c 'import sys; print(sys.version.split()[0])')"
	phase_icons
	phase_freeze
	APP="$DIST/$APP_NAME.app"
	phase_check
	phase_smoke
	[ "$gui" -eq 0 ] || phase_gui
	[ "$dmg" -eq 0 ] || phase_dmg
	say "done"
}

# Sourcing this file (the tests do) defines the functions and runs nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi

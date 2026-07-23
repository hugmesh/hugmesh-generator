#!/usr/bin/env sh
# HugMesh mesh-node — LINUX installer (FD-09). Installs the launcher, an app icon,
# app-menu entries (Up / Status / Leave), and OPTIONALLY a login autostart + a system
# tray indicator — all into per-user XDG dirs, NO root required. Pairs with the
# Windows install.ps1. See README.md.
#
# Usage:
#   ./install.sh --keys ./mykeys [--role user|mod|admin|superadmin] [--name HOST]
#                [--image IMG] [--autostart] [--tray]
#   ./install.sh --uninstall
set -eu

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
APP_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
ICON_SCALABLE="${XDG_DATA_HOME:-${HOME}/.local/share}/icons/hicolor/scalable/apps"
ICON_256="${XDG_DATA_HOME:-${HOME}/.local/share}/icons/hicolor/256x256/apps"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/autostart"
CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/hugmesh-mesh"
CFG="${CFG_DIR}/launch.env"
ICON_NAME="hugmesh-mesh-node"

KEYS=""; ROLE=""; HOST=""; IMAGE=""; AUTOSTART=0; TRAY=0; UNINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --keys)  KEYS="$2"; shift 2 ;;
        --role)  ROLE="$2"; shift 2 ;;
        --name)  HOST="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --autostart) AUTOSTART=1; shift ;;
        --tray)  TRAY=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

refresh_caches() {
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "${APP_DIR}" 2>/dev/null || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -t "${XDG_DATA_HOME:-${HOME}/.local/share}/icons/hicolor" 2>/dev/null || true
}

if [ "${UNINSTALL}" = 1 ]; then
    rm -f "${BIN_DIR}/hugmesh-mesh-node" "${BIN_DIR}/hugmesh-mesh-ctl" "${BIN_DIR}/hugmesh-mesh-tray.py"
    rm -f "${APP_DIR}/hugmesh-mesh-node.desktop" "${APP_DIR}/hugmesh-mesh-status.desktop" "${APP_DIR}/hugmesh-mesh-leave.desktop"
    rm -f "${AUTOSTART_DIR}/hugmesh-mesh-node.desktop" "${AUTOSTART_DIR}/hugmesh-mesh-tray.desktop"
    rm -f "${ICON_SCALABLE}/${ICON_NAME}.svg" "${ICON_256}/${ICON_NAME}.png"
    refresh_caches
    echo "uninstalled hugmesh mesh-node (launcher, menu entries, autostart, tray). Config kept at ${CFG_DIR} (rm it to fully clean)."
    exit 0
fi

[ -n "${KEYS}" ] || { echo "ERROR: --keys <dir> is required (the local KEYS folder)." >&2; exit 2; }
[ -d "${KEYS}" ] || { echo "ERROR: keys dir not found: ${KEYS}" >&2; exit 2; }
KEYS_ABS="$(cd "${KEYS}" && pwd)"

# ── Validate the values that get written into the SOURCED launch.env (#18) ─────
# hugmesh-mesh-ctl dot-sources launch.env, so an unescaped value containing
# $(...)/`...`/;/newline would execute as the user. Validate up front (fail closed)
# AND single-quote-escape on write (defense-in-depth). ROLE is a tiny enum; NAME/
# IMAGE get a conservative charset allowlist (container name + OCI ref chars).
case "${ROLE}" in
    ""|user|mod|admin|superadmin) : ;;
    *) echo "ERROR: invalid --role '${ROLE}' (allowed: user|mod|admin|superadmin)" >&2; exit 2 ;;
esac
case "${HOST}" in
    *[!A-Za-z0-9._-]*) echo "ERROR: invalid --name '${HOST}' (allowed: A-Za-z0-9._-)" >&2; exit 2 ;;
esac
case "${IMAGE}" in
    *[!A-Za-z0-9._:/@-]*) echo "ERROR: invalid --image '${IMAGE}' (allowed: A-Za-z0-9._:/@-)" >&2; exit 2 ;;
esac

# Emit `KEY='value'` with embedded single-quotes safely escaped, so the file can
# be dot-sourced without code execution even if validation above is ever relaxed.
# (POSIX sh — no `printf %q`; this is the portable single-quote-escape idiom.)
sq_emit() {
    # $1=KEY  $2=VALUE
    printf "%s='" "$1"
    printf '%s' "$2" | sed "s/'/'\\\\''/g"
    printf "'\n"
}

mkdir -p "${BIN_DIR}" "${APP_DIR}" "${ICON_SCALABLE}" "${ICON_256}" "${CFG_DIR}"

# 1) launcher + a tiny config-sourcing control wrapper
install -m0755 "${SELF_DIR}/mesh-node.sh" "${BIN_DIR}/hugmesh-mesh-node"
cat > "${BIN_DIR}/hugmesh-mesh-ctl" <<'CTL'
#!/usr/bin/env sh
# Reads ~/.config/hugmesh-mesh/launch.env and drives the mesh-node launcher.
set -eu
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/hugmesh-mesh/launch.env"
[ -f "${CFG}" ] && . "${CFG}"
LAUNCHER="$(dirname "$0")/hugmesh-mesh-node"
case "${1:-up}" in
    up)   exec "${LAUNCHER}" --keys "${KEYS:?set KEYS in ${CFG}}" ${ROLE:+--role "${ROLE}"} ${NAME:+--name "${NAME}"} ${IMAGE:+--image "${IMAGE}"} ;;
    logs) exec "${LAUNCHER}" --logs ;;
    stop) exec "${LAUNCHER}" --stop ;;
    *) echo "usage: hugmesh-mesh-ctl up|logs|stop" >&2; exit 2 ;;
esac
CTL
chmod 0755 "${BIN_DIR}/hugmesh-mesh-ctl"

# 2) launch config (single source of truth for the menu/tray/autostart)
# Values are single-quote-escaped so this dot-sourced file can never execute
# injected code (#18); ROLE/NAME/IMAGE were also charset-validated above.
{
    echo "# written by hugmesh mesh-node install.sh"
    sq_emit KEYS  "${KEYS_ABS}"
    sq_emit ROLE  "${ROLE}"
    sq_emit NAME  "${HOST}"
    sq_emit IMAGE "${IMAGE}"
} > "${CFG}"
chmod 0600 "${CFG}"

# 3) icon
install -m0644 "${SELF_DIR}/icons/${ICON_NAME}.svg" "${ICON_SCALABLE}/${ICON_NAME}.svg"
[ -f "${SELF_DIR}/icons/${ICON_NAME}.png" ] && install -m0644 "${SELF_DIR}/icons/${ICON_NAME}.png" "${ICON_256}/${ICON_NAME}.png" || true

# 4) app-menu entries (run in a terminal so the user sees the Casdoor code on Up)
mk_desktop() { # name, comment, exec, terminal
    cat > "${APP_DIR}/$1.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$2
Comment=$3
Exec=$4
Icon=${ICON_NAME}
Terminal=$5
Categories=Network;System;
StartupNotify=false
EOF
}
mk_desktop hugmesh-mesh-node   "HugMesh Mesh — Join"  "Join this machine to the HugMesh mesh" "${BIN_DIR}/hugmesh-mesh-ctl up"   true
mk_desktop hugmesh-mesh-status "HugMesh Mesh — Status/Logs" "Follow the mesh-node logs"          "${BIN_DIR}/hugmesh-mesh-ctl logs" true
mk_desktop hugmesh-mesh-leave  "HugMesh Mesh — Leave" "Stop + remove the mesh-node container"    "${BIN_DIR}/hugmesh-mesh-ctl stop" false

# 5) optional: start the node at login
if [ "${AUTOSTART}" = 1 ]; then
    mkdir -p "${AUTOSTART_DIR}"
    cat > "${AUTOSTART_DIR}/hugmesh-mesh-node.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=HugMesh Mesh (autostart)
Comment=Bring up the HugMesh mesh node at login
Exec=${BIN_DIR}/hugmesh-mesh-ctl up
Icon=${ICON_NAME}
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    echo "autostart: node will join the mesh at login."
fi

# 6) optional: system tray indicator
if [ "${TRAY}" = 1 ]; then
    install -m0755 "${SELF_DIR}/tray/hugmesh-mesh-tray.py" "${BIN_DIR}/hugmesh-mesh-tray.py"
    mkdir -p "${AUTOSTART_DIR}"
    cat > "${AUTOSTART_DIR}/hugmesh-mesh-tray.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=HugMesh Mesh Tray
Comment=HugMesh mesh-node tray indicator
Exec=${BIN_DIR}/hugmesh-mesh-tray.py
Icon=${ICON_NAME}
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    if python3 -c "import gi; gi.require_version('AyatanaAppIndicator3','0.1')" 2>/dev/null \
       || python3 -c "import gi; gi.require_version('AppIndicator3','0.1')" 2>/dev/null; then
        echo "tray: installed (AppIndicator found). Launch now with: hugmesh-mesh-tray.py"
    else
        echo "tray: installed, but no AppIndicator GI typelib found. Install one for the icon to appear, e.g.:"
        echo "      Debian/Ubuntu: gir1.2-ayatanaappindicator3-0.1 + python3-gi"
        echo "      Fedora:        libayatana-appindicator-gtk3 + python3-gobject"
        echo "      (menu entries + autostart still work without it.)"
    fi
fi

refresh_caches
echo "installed hugmesh mesh-node:"
echo "  launcher : ${BIN_DIR}/hugmesh-mesh-node  (+ hugmesh-mesh-ctl)"
echo "  menu     : 'HugMesh Mesh — Join / Status / Leave'  (icon: ${ICON_NAME})"
echo "  config   : ${CFG}  (KEYS=${KEYS_ABS} ROLE=${ROLE:-user})"
echo "Ensure ${BIN_DIR} is on your PATH. Join now from the menu, or: hugmesh-mesh-ctl up"

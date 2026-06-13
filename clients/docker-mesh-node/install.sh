#!/usr/bin/env sh
# Snapdragon mesh-node — LINUX installer (FD-09). Installs the launcher, an app icon,
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
CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/snapdragon-mesh"
CFG="${CFG_DIR}/launch.env"
ICON_NAME="snapdragon-mesh-node"

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
    rm -f "${BIN_DIR}/snapdragon-mesh-node" "${BIN_DIR}/snapdragon-mesh-ctl" "${BIN_DIR}/snapdragon-mesh-tray.py"
    rm -f "${APP_DIR}/snapdragon-mesh-node.desktop" "${APP_DIR}/snapdragon-mesh-status.desktop" "${APP_DIR}/snapdragon-mesh-leave.desktop"
    rm -f "${AUTOSTART_DIR}/snapdragon-mesh-node.desktop" "${AUTOSTART_DIR}/snapdragon-mesh-tray.desktop"
    rm -f "${ICON_SCALABLE}/${ICON_NAME}.svg" "${ICON_256}/${ICON_NAME}.png"
    refresh_caches
    echo "uninstalled snapdragon mesh-node (launcher, menu entries, autostart, tray). Config kept at ${CFG_DIR} (rm it to fully clean)."
    exit 0
fi

[ -n "${KEYS}" ] || { echo "ERROR: --keys <dir> is required (the local KEYS folder)." >&2; exit 2; }
[ -d "${KEYS}" ] || { echo "ERROR: keys dir not found: ${KEYS}" >&2; exit 2; }
KEYS_ABS="$(cd "${KEYS}" && pwd)"

mkdir -p "${BIN_DIR}" "${APP_DIR}" "${ICON_SCALABLE}" "${ICON_256}" "${CFG_DIR}"

# 1) launcher + a tiny config-sourcing control wrapper
install -m0755 "${SELF_DIR}/mesh-node.sh" "${BIN_DIR}/snapdragon-mesh-node"
cat > "${BIN_DIR}/snapdragon-mesh-ctl" <<'CTL'
#!/usr/bin/env sh
# Reads ~/.config/snapdragon-mesh/launch.env and drives the mesh-node launcher.
set -eu
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/snapdragon-mesh/launch.env"
[ -f "${CFG}" ] && . "${CFG}"
LAUNCHER="$(dirname "$0")/snapdragon-mesh-node"
case "${1:-up}" in
    up)   exec "${LAUNCHER}" --keys "${KEYS:?set KEYS in ${CFG}}" ${ROLE:+--role "${ROLE}"} ${NAME:+--name "${NAME}"} ${IMAGE:+--image "${IMAGE}"} ;;
    logs) exec "${LAUNCHER}" --logs ;;
    stop) exec "${LAUNCHER}" --stop ;;
    *) echo "usage: snapdragon-mesh-ctl up|logs|stop" >&2; exit 2 ;;
esac
CTL
chmod 0755 "${BIN_DIR}/snapdragon-mesh-ctl"

# 2) launch config (single source of truth for the menu/tray/autostart)
{
    echo "# written by snapdragon mesh-node install.sh"
    printf 'KEYS=%s\n'  "${KEYS_ABS}"
    printf 'ROLE=%s\n'  "${ROLE}"
    printf 'NAME=%s\n'  "${HOST}"
    printf 'IMAGE=%s\n' "${IMAGE}"
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
mk_desktop snapdragon-mesh-node   "Snapdragon Mesh — Join"  "Join this machine to the Snapdragon mesh" "${BIN_DIR}/snapdragon-mesh-ctl up"   true
mk_desktop snapdragon-mesh-status "Snapdragon Mesh — Status/Logs" "Follow the mesh-node logs"          "${BIN_DIR}/snapdragon-mesh-ctl logs" true
mk_desktop snapdragon-mesh-leave  "Snapdragon Mesh — Leave" "Stop + remove the mesh-node container"    "${BIN_DIR}/snapdragon-mesh-ctl stop" false

# 5) optional: start the node at login
if [ "${AUTOSTART}" = 1 ]; then
    mkdir -p "${AUTOSTART_DIR}"
    cat > "${AUTOSTART_DIR}/snapdragon-mesh-node.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Snapdragon Mesh (autostart)
Comment=Bring up the Snapdragon mesh node at login
Exec=${BIN_DIR}/snapdragon-mesh-ctl up
Icon=${ICON_NAME}
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    echo "autostart: node will join the mesh at login."
fi

# 6) optional: system tray indicator
if [ "${TRAY}" = 1 ]; then
    install -m0755 "${SELF_DIR}/tray/snapdragon-mesh-tray.py" "${BIN_DIR}/snapdragon-mesh-tray.py"
    mkdir -p "${AUTOSTART_DIR}"
    cat > "${AUTOSTART_DIR}/snapdragon-mesh-tray.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Snapdragon Mesh Tray
Comment=Snapdragon mesh-node tray indicator
Exec=${BIN_DIR}/snapdragon-mesh-tray.py
Icon=${ICON_NAME}
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    if python3 -c "import gi; gi.require_version('AyatanaAppIndicator3','0.1')" 2>/dev/null \
       || python3 -c "import gi; gi.require_version('AppIndicator3','0.1')" 2>/dev/null; then
        echo "tray: installed (AppIndicator found). Launch now with: snapdragon-mesh-tray.py"
    else
        echo "tray: installed, but no AppIndicator GI typelib found. Install one for the icon to appear, e.g.:"
        echo "      Debian/Ubuntu: gir1.2-ayatanaappindicator3-0.1 + python3-gi"
        echo "      Fedora:        libayatana-appindicator-gtk3 + python3-gobject"
        echo "      (menu entries + autostart still work without it.)"
    fi
fi

refresh_caches
echo "installed snapdragon mesh-node:"
echo "  launcher : ${BIN_DIR}/snapdragon-mesh-node  (+ snapdragon-mesh-ctl)"
echo "  menu     : 'Snapdragon Mesh — Join / Status / Leave'  (icon: ${ICON_NAME})"
echo "  config   : ${CFG}  (KEYS=${KEYS_ABS} ROLE=${ROLE:-user})"
echo "Ensure ${BIN_DIR} is on your PATH. Join now from the menu, or: snapdragon-mesh-ctl up"

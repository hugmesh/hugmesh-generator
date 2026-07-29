#!/usr/bin/env sh
# HugMesh mesh-node — LINUX onboarding (FD-09). Make THIS machine a background
# HugMesh mesh node via Docker, using LOCAL FILE KEYS + a one-line Casdoor login.
# No OS flash. Mirrors mesh-node.ps1 (Windows). See README.md.
#
# Usage:
#   ./mesh-node.sh --keys ./mykeys [--role user|mod|admin|superadmin] [--name HOST]
#                  [--image IMG] [--build] [--stop] [--logs]
#
# The keys dir mirrors the KEYS-USB layout (tailscale/authkey, login-server,
# casdoor.json, role) the appliance images consume.
set -eu
IMAGE="${SNAP_MESH_IMAGE:-hugmesh/mesh-node:latest}"
NAME="hugmesh-mesh-node"
KEYS=""; ROLE=""; HOST=""; BUILD=0; STOP=0; LOGS=0
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

while [ $# -gt 0 ]; do
    case "$1" in
        --keys)  KEYS="$2"; shift 2 ;;
        --role)  ROLE="$2"; shift 2 ;;
        --name)  HOST="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --build) BUILD=1; shift ;;
        --stop)  STOP=1; shift ;;
        --logs)  LOGS=1; shift ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found (install Docker Engine)." >&2; exit 1; }

if [ "$STOP" = 1 ]; then docker rm -f "$NAME" >/dev/null 2>&1 && echo "stopped + removed $NAME" || echo "$NAME not running"; exit 0; fi
if [ "$LOGS" = 1 ]; then exec docker logs -f "$NAME"; fi
if [ "$BUILD" = 1 ]; then echo "building $IMAGE ..."; docker build -t "$IMAGE" "$SELF_DIR"; fi

[ -n "$KEYS" ] || { echo "ERROR: --keys <dir> is required (the local KEYS folder)." >&2; exit 2; }
[ -d "$KEYS" ] || { echo "ERROR: keys dir not found: $KEYS" >&2; exit 2; }
KEYS_ABS="$(cd "$KEYS" && pwd)"

# Full kernel routing when /dev/net/tun exists; else the container falls back to
# userspace networking (still joins the tailnet) — the entrypoint detects this.
TUN_ARGS=""
[ -c /dev/net/tun ] && TUN_ARGS="--cap-add=NET_ADMIN --device=/dev/net/tun"

docker rm -f "$NAME" >/dev/null 2>&1 || true
# shellcheck disable=SC2086
docker run -d --name "$NAME" --restart unless-stopped \
    -v "$KEYS_ABS:/keys:ro" \
    -v hugmesh-meshnode-state:/var/lib/tailscale \
    $TUN_ARGS \
    ${ROLE:+-e SNAP_ROLE="$ROLE"} \
    ${HOST:+-e SNAP_HOSTNAME="$HOST"} \
    "$IMAGE"

echo "mesh-node started (container: $NAME). Follow the join + Casdoor login with:"
echo "    docker logs -f $NAME      (or:  $0 --logs)"
echo "Leave the mesh with:  $0 --stop"

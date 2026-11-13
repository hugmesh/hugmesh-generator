#!/usr/bin/env bash
# mint-control-onion.sh — create the control onion key for mesh control over Tor
# (docs/MESH-CONTROL-OVER-TOR.md) on THIS computer, with tor's network off: nothing
# leaves the computer.
#
#   mint-control-onion.sh DIR      mint into DIR (an existing hostname there: nothing
#                                  to do; a secret key with no hostname: refused)
#   mint-control-onion.sh --check  exit 0 when this computer can mint, else say why
#
# tor runs from PATH, or, with MESH_CONTROL_TOR_IMAGE=<an image with tor>, in docker.
# gen-provision-keys.sh calls this at KEYS time. The Makefile's docker leg and
# build-all-roles.sh call it BEFORE any image is built: the builder image carries no
# tor, so a mint left to the keys step inside it failed only after every image build.
set -euo pipefail

PORT="${MESH_CONTROL_PORT:-7443}"
TOR_IMAGE="${MESH_CONTROL_TOR_IMAGE:-}"

can_mint() {
    command -v tor >/dev/null 2>&1 && return 0
    [ -n "${TOR_IMAGE}" ] && command -v docker >/dev/null 2>&1 && return 0
    echo "ERROR: minting the control onion needs tor on this computer (or MESH_CONTROL_TOR_IMAGE=<an image with tor> and docker)" >&2
    return 1
}

case "${1:-}" in
    --check) can_mint; exit $? ;;
    ""|-*) echo "usage: $0 DIR | --check" >&2; exit 2 ;;
esac
DIR="$1"

[ -s "${DIR}/hostname" ] && exit 0
if [ -e "${DIR}/hs_ed25519_secret_key" ]; then
    echo "ERROR: ${DIR} has a secret key but no hostname — refusing to mint over it" >&2; exit 1
fi
can_mint || exit 1
mkdir -p "${DIR}" && chmod 0700 "${DIR}"
echo "==> Minting the control onion key in ${DIR} (tor, DisableNetwork — nothing leaves this computer)"
_mc_tmp="$(mktemp -d)"; : > "${_mc_tmp}/torrc"   # tor refuses /dev/null as a torrc
_mc_ctr=""
if command -v tor >/dev/null 2>&1; then
    tor --defaults-torrc "${_mc_tmp}/torrc" -f "${_mc_tmp}/torrc" --DisableNetwork 1 --SocksPort 0 \
        --DataDirectory "${_mc_tmp}/data" --HiddenServiceDir "${DIR}" \
        --HiddenServicePort "${PORT} 127.0.0.1:8080" --Log "notice file ${_mc_tmp}/tor.log" >/dev/null 2>&1 &
else
    _mc_ctr="hugmesh-mint-$$-${RANDOM}"
    docker run --rm --name "${_mc_ctr}" --network none --user "$(id -u):$(id -g)" -v "$(cd "${DIR}" && pwd):/hs" \
        "${TOR_IMAGE}" sh -c ': > /tmp/torrc; exec tor --defaults-torrc /tmp/torrc -f /tmp/torrc --DisableNetwork 1 --SocksPort 0 --DataDirectory /tmp/data --HiddenServiceDir /hs --HiddenServicePort "'"${PORT}"' 127.0.0.1:8080"' >/dev/null 2>&1 &
fi
_mc_pid=$!
# Wait for ALL the files tor writes (hostname last is not guaranteed), then stop it
# and reap it WITHOUT letting its exit status end this script: a SIGTERM that lands
# before tor installs its signal handlers exits 143, which `wait` returned and
# `set -e` turned into a silent abort (measured 15 of 15 when killed the instant
# the hostname appeared). Success is judged by the files, never by tor's status.
for _i in $(seq 1 120); do
    [ -s "${DIR}/hostname" ] && [ -s "${DIR}/hs_ed25519_secret_key" ] \
        && [ -s "${DIR}/hs_ed25519_public_key" ] && break
    kill -0 "${_mc_pid}" 2>/dev/null || break
    sleep 0.5
done
if [ -n "${_mc_ctr}" ]; then docker rm -f "${_mc_ctr}" >/dev/null 2>&1 || true; fi
kill "${_mc_pid}" 2>/dev/null || true
wait "${_mc_pid}" 2>/dev/null || true
rm -rf "${_mc_tmp}"
if ! { [ -s "${DIR}/hostname" ] && [ -s "${DIR}/hs_ed25519_secret_key" ]; }; then
    echo "ERROR: tor did not mint a control onion key in ${DIR}" >&2; exit 1
fi

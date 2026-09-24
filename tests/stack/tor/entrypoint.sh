#!/bin/sh
# hugmesh-tor entrypoint — ONE image, TWO roles, selected by HUGMESH_TOR_ROLE:
#
#   onion  (default; compose service `hugmesh-tor`)
#     Generate a managed torrc that maps a v3 onion onto the in-compose front
#     door, run tor, and copy the minted .onion HOSTNAME (public — NOT the private
#     key) to the bind-mounted /onion-out so the host/GUI can read it. The private
#     key persists in the tor-onion-keys named volume, so the address is STABLE
#     across restarts. This is the single-container dev analogue of
#     specs/.../hugmesh-tor-reconcile's key custody model (docs/TOR-HIDDEN-SERVICE.md).
#
#   client (compose service `hugmesh-tor-client`)
#     A plain Tor CLIENT: a SOCKS5 proxy on :9050 and nothing else — no onion, no
#     relay. The e2e lane's browser dials the onion above through it
#     (`make stack-e2e-tor`); Tor Browser on the host would use its own.
#
# TWO PORTS, AND WHY :443 IS NOT OPTIONAL (hugmesh-generator#586, measured
# 2026-09-23 with the host tor and the cached Playwright chromium, no docker):
# the fe-gateway emits `Content-Security-Policy: … upgrade-insecure-requests` on
# every response, and on a page loaded from http://<onion>/ Chromium upgrades
# every same-origin subresource to https://<onion>/. With only :80 published the
# upgraded script died `net::ERR_SOCKS_CONNECTION_FAILED` and the SPA never
# booted; with :443 published but the page entered over http, the upgraded
# fetch() became CROSS-ORIGIN and died `net::ERR_FAILED`. Entered over
# https://<onion>/ with :443 served, script and fetch both succeeded. So :443 ->
# the stack's TLS front (its self-signed cert: a Tor Browser user accepts the
# warning once; the e2e runs with ignoreHTTPSErrors) is the door, and :80 stays
# for plain clients (curl, the anubis gate). The node agent already publishes
# :443 (specs/usr/sbin/hugmesh-tor-reconcile), so this also matches the device.
#
# Test seams (tests/stack/tor_flip_wiring.py drives this script with a stub tor):
# HUGMESH_TOR_DATA_DIR, HUGMESH_TOR_OUT_DIR, HUGMESH_TOR_TORRC, HUGMESH_TOR_BIN.
# Their defaults are the container paths and nothing in compose sets them.
set -eu

ROLE="${HUGMESH_TOR_ROLE:-onion}"
UPSTREAM="${TOR_ONION_UPSTREAM:-hugmesh-fe-gateway:8080}"
TLS_UPSTREAM="${TOR_ONION_TLS_UPSTREAM:-hugmesh-https-front:8443}"
DATA_DIR="${HUGMESH_TOR_DATA_DIR:-/var/lib/tor}"
OUT_DIR="${HUGMESH_TOR_OUT_DIR:-/onion-out}"
TORRC="${HUGMESH_TOR_TORRC:-/etc/tor/torrc}"
TOR_BIN="${HUGMESH_TOR_BIN:-tor}"
HS_DIR="${DATA_DIR}/hugmesh-onion"
# tor's own notice log, read by the compose healthchecks ("Bootstrapped 100%").
# TRUNCATED at every start: `restart: unless-stopped` restarts the SAME container,
# whose filesystem (and therefore an old "Bootstrapped 100%" line) survives.
NOTICE_LOG="${DATA_DIR}/notice.log"

case "${ROLE}" in
  onion|client) ;;
  *) echo "[hugmesh-tor] FATAL: HUGMESH_TOR_ROLE='${ROLE}' (expected onion|client)" >&2; exit 2 ;;
esac

mkdir -p "$DATA_DIR"
: > "$NOTICE_LOG"

if [ "${ROLE}" = "client" ]; then
  # tor refuses a DataDirectory it cannot own once it has setuid'd to `User tor`.
  chown -R tor:tor "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  # SocksPort on every container interface so compose can publish it, and a
  # SocksPolicy that admits only loopback + the private ranges docker's bridge
  # uses (the published connection arrives from the bridge gateway). Compose
  # publishes it on 127.0.0.1 ONLY — never a LAN-reachable open proxy.
  cat > "$TORRC" <<TORRC_EOF
DataDirectory $DATA_DIR
User tor
SocksPort 0.0.0.0:9050
SocksPolicy accept 127.0.0.0/8
SocksPolicy accept 10.0.0.0/8
SocksPolicy accept 172.16.0.0/12
SocksPolicy accept 192.168.0.0/16
SocksPolicy reject *
Log notice stdout
Log notice file $NOTICE_LOG
TORRC_EOF
  exec "$TOR_BIN" -f "$TORRC"
fi

mkdir -p "$HS_DIR" "$OUT_DIR"
# hugmesh-generator#581: the published hostname is a READOUT of this container's
# key, so it must never outlive the container. Remove whatever an earlier run left
# BEFORE anything can read it as current: after `make stack-down` (down -v drops
# the key volume) the next up mints a NEW onion, and a leftover file would announce
# the dead one until the publisher below overwrote it — a window every reader
# (Studio monitor, Copy .onion, saved-mesh capture, _await_onion) could hit.
rm -f "$OUT_DIR/hostname"
# tor REFUSES a HiddenServiceDir that is not mode 0700 owned by the tor user, and
# (after it setuid's to `User tor` below) needs to WRITE its own state/lock/cache
# files directly under DataDirectory too — chown the whole tree, not just HS_DIR,
# so a startup here never depends on the alpine tor package having preset it.
chown -R tor:tor "$DATA_DIR"
chmod 700 "$HS_DIR"

cat > "$TORRC" <<TORRC_EOF
DataDirectory $DATA_DIR
User tor
# We SERVE an onion — we are not a SOCKS proxy and not a relay.
SocksPort 0
HiddenServiceDir $HS_DIR
HiddenServiceVersion 3
HiddenServicePort 80 $UPSTREAM
HiddenServicePort 443 $TLS_UPSTREAM
Log notice stdout
Log notice file $NOTICE_LOG
TORRC_EOF

# Publish the hostname out once tor mints it (first boot ~1s; already present on a
# restart). The hostname is PUBLIC; only the key stays inside the named volume.
(
  i=0
  while [ ! -s "$HS_DIR/hostname" ] && [ "$i" -lt 120 ]; do sleep 1; i=$((i + 1)); done
  if [ -s "$HS_DIR/hostname" ]; then
    cp "$HS_DIR/hostname" "$OUT_DIR/hostname"
    chmod 644 "$OUT_DIR/hostname" 2>/dev/null || true
    echo "[hugmesh-tor] onion published for :80->${UPSTREAM} :443->${TLS_UPSTREAM} -> $(cat "$OUT_DIR/hostname")"
  else
    echo "[hugmesh-tor] WARNING: hostname not minted within 120s" >&2
  fi
) &
PUBLISHER_PID=$!

# tor runs as a CHILD, not via exec, so this script is still here when the
# container stops and can take the readout down with it (#581): a stopped mesh
# has no onion door, and the file must say so. `stack-halt` keeps the key volume,
# so the next up republishes the SAME address; `stack-down` drops it, so the next
# up publishes a NEW one — either way nothing reads a hostname tor is not serving.
"$TOR_BIN" -f "$TORRC" &
TOR_PID=$!

unpublish() {
  kill "$PUBLISHER_PID" 2>/dev/null || true
  wait "$PUBLISHER_PID" 2>/dev/null || true
  rm -f "$OUT_DIR/hostname"
}
on_stop() {
  kill -TERM "$TOR_PID" 2>/dev/null || true
  wait "$TOR_PID" 2>/dev/null || true
  unpublish
  exit 0
}
trap on_stop TERM INT

set +e
wait "$TOR_PID"
rc=$?
set -e
# tor exited on its own (crash, bad config): unpublish, then let compose's
# restart policy bring the container back and republish.
unpublish
exit "$rc"

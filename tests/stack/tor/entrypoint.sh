#!/bin/sh
# hugmesh-tor entrypoint — generate a managed torrc that maps a v3 onion :80 ->
# the in-compose fe-gateway ingress, then run tor in the foreground. The minted
# .onion HOSTNAME (public — NOT the private key) is copied to the bind-mounted
# /onion-out so the host/GUI can read it; the private key persists in the
# tor-onion-keys named volume so the address is STABLE across restarts. This is the
# single-container dev analogue of specs/.../hugmesh-tor-reconcile's key custody
# model (docs/TOR-HIDDEN-SERVICE.md).
set -eu

UPSTREAM="${TOR_ONION_UPSTREAM:-hugmesh-fe-gateway:8080}"
DATA_DIR="/var/lib/tor"
HS_DIR="${DATA_DIR}/hugmesh-onion"
OUT_DIR="/onion-out"

mkdir -p "$HS_DIR" "$OUT_DIR"
# tor REFUSES a HiddenServiceDir that is not mode 0700 owned by the tor user, and
# (after it setuid's to `User tor` below) needs to WRITE its own state/lock/cache
# files directly under DataDirectory too — chown the whole tree, not just HS_DIR,
# so a startup here never depends on the alpine tor package having preset it.
chown -R tor:tor "$DATA_DIR"
chmod 700 "$HS_DIR"

cat > /etc/tor/torrc <<EOF
DataDirectory /var/lib/tor
User tor
# We SERVE an onion — we are not a SOCKS proxy and not a relay.
SocksPort 0
HiddenServiceDir $HS_DIR
HiddenServiceVersion 3
HiddenServicePort 80 $UPSTREAM
Log notice stdout
EOF

# Publish the hostname out once tor mints it (first boot ~1s; already present on a
# restart). The hostname is PUBLIC; only the key stays inside the named volume.
(
  i=0
  while [ ! -s "$HS_DIR/hostname" ] && [ "$i" -lt 120 ]; do sleep 1; i=$((i + 1)); done
  if [ -s "$HS_DIR/hostname" ]; then
    cp "$HS_DIR/hostname" "$OUT_DIR/hostname"
    chmod 644 "$OUT_DIR/hostname" 2>/dev/null || true
    echo "[hugmesh-tor] onion published for ${UPSTREAM} -> $(cat "$OUT_DIR/hostname")"
  else
    echo "[hugmesh-tor] WARNING: hostname not minted within 120s" >&2
  fi
) &

exec tor -f /etc/tor/torrc

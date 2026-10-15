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
# TWO PORTS (hugmesh-generator#586, #628). :443 -> the stack's TLS front is the
# door (its self-signed cert: a Tor Browser user accepts the warning once; the
# e2e runs with ignoreHTTPSErrors). Why https: a secure context (Chromium does
# not treat an http .onion as one), a Secure session cookie on a
# production-configured mesh, and the node agent already publishes :443
# (specs/usr/sbin/hugmesh-tor-reconcile), so this matches the device. :80 stays
# for plain clients (curl, the anubis gate). An earlier comment here blamed CSP
# upgrade-insecure-requests for an SPA that could not boot over http; measured
# live on 2026-09-24 the SPA document never carries that directive and the SPA
# boots over http://<onion>/ with nothing upgraded (docs/TOR-HIDDEN-SERVICE.md
# "Why :443").
#
# PER-DOMAIN ONIONS (hugmesh-generator#582, operator decision 68 = A on #347): "a Tor
# domain = its own HiddenService stanza fronting the SAME gateway, distinguished by
# the onion Host". TOR_ONION_DOMAINS lists them, space- or comma-separated, each
# `<slug>=<tenant>` (or a bare `<slug>`, tenant = slug):
#   * <slug>   names the key directory, HiddenServiceDir $DATA_DIR/hugmesh-onion.d/<slug>
#              (its own named volume, so each address is as stable as the primary),
#              and the readout /onion-out/<slug>.hostname. The node contract's shape,
#              [a-z0-9][a-z0-9-]{0,62} (specs/usr/sbin/hugmesh-tor-reconcile, #599);
#              anything else is refused and logged, a repeat is skipped.
#   * <tenant> is the gateway tenancy key the onion Host maps to — `default`, or the
#              domain's own brand key (the APP_TENANCY_HOSTS value of its HTTPS door).
# The HOST MAP the gateway reads (APP_TENANCY_HOSTS_FILE, hugmesh-gateway#38/#39) is
# written here too, because only this container knows the minted addresses: the
# mesh's own onion as `default` (contract point 1 — once the file is set EVERY
# unregistered onion is refused, the primary included) and one `<onion>=<tenant>`
# per domain, written to a temp file in the same directory and RENAMED into place
# (point 2 — the gateway re-reads it every 5 s non-atomically). Only names shaped
# like a v3 onion are written: the map decides which brand a Host is served as.
# Like the hostname readouts, it never outlives the container: removed before tor
# starts, on stop and when tor dies.
#
# THE MAP IS WRITTEN ONLY WHERE ITS DIRECTORY EXISTS. compose mounts /tenancy through
# the tests/stack/compose.tor-domains.yaml overlay, which the Makefile loads only for
# a TOR=1 stack that has a Tor domain. So on a stack with no Tor domain this script
# does what it always did: the same torrc byte for byte, the same one readout, no
# map, no new directory.
#
# Paths a test can point elsewhere (tests/stack/tor_flip_wiring.py and
# studio/tests/test_domain_services_tor.py run this script against a stub tor):
# HUGMESH_TOR_DATA_DIR, HUGMESH_TOR_OUT_DIR, HUGMESH_TOR_TORRC, HUGMESH_TOR_BIN,
# HUGMESH_TOR_MAP_DIR. Their defaults are the container paths and nothing in compose
# sets them.
set -eu

ROLE="${HUGMESH_TOR_ROLE:-onion}"
UPSTREAM="${TOR_ONION_UPSTREAM:-hugmesh-fe-gateway:8080}"
TLS_UPSTREAM="${TOR_ONION_TLS_UPSTREAM:-hugmesh-https-front:8443}"
DATA_DIR="${HUGMESH_TOR_DATA_DIR:-/var/lib/tor}"
OUT_DIR="${HUGMESH_TOR_OUT_DIR:-/onion-out}"
TORRC="${HUGMESH_TOR_TORRC:-/etc/tor/torrc}"
TOR_BIN="${HUGMESH_TOR_BIN:-tor}"
HS_DIR="${DATA_DIR}/hugmesh-onion"
# Per-domain key directories (#582) — a SEPARATE named volume in compose, never
# nested inside the primary's HiddenServiceDir.
DOMAIN_HS_ROOT="${DATA_DIR}/hugmesh-onion.d"
# The gateway host map (hugmesh-gateway#38) — a named volume the overlay mounts here
# and, read-only, in the fe-gateway; APP_TENANCY_HOSTS_FILE points at MAP_FILE.
MAP_DIR="${HUGMESH_TOR_MAP_DIR:-/tenancy}"
MAP_FILE="${MAP_DIR}/onion-hosts.map"
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

# ── the per-domain list (#582) ─────────────────────────────────────────────────
# One validated `<slug> <tenant>` line per domain, in the order given, repeats
# dropped. POSIX `case` rather than grep: busybox grep is where a NEGATIVE shape
# check fails open.
valid_key() {
  case "$1" in ''|[!a-z0-9]*|*[!a-z0-9-]*) return 1 ;; esac
  [ "${#1}" -le 63 ]
}
DOMAIN_LINES=""
SEEN_SLUGS=" "
set -f
for tok in $(printf '%s' "${TOR_ONION_DOMAINS:-}" | tr ',' ' '); do
  slug="${tok%%=*}"
  tenant="${tok#*=}"
  [ "$tok" = "$slug" ] && tenant="$slug"
  if ! valid_key "$slug" || ! valid_key "$tenant"; then
    echo "[hugmesh-tor] REFUSED TOR_ONION_DOMAINS entry '${tok}' (want <slug>=<tenant>, each [a-z0-9][a-z0-9-]{0,62})" >&2
    continue
  fi
  case "$SEEN_SLUGS" in
    *" $slug "*) echo "[hugmesh-tor] skipped a repeated TOR_ONION_DOMAINS slug '${slug}'" >&2; continue ;;
  esac
  SEEN_SLUGS="${SEEN_SLUGS}${slug} "
  DOMAIN_LINES="${DOMAIN_LINES}${slug} ${tenant}
"
done
set +f
if [ -n "$DOMAIN_LINES" ] && [ ! -d "$MAP_DIR" ]; then
  echo "[hugmesh-tor] NOTE: Tor domains are listed but $MAP_DIR is not mounted, so no gateway host map is written and every onion is served as the default brand (the map comes with tests/stack/compose.tor-domains.yaml)" >&2
fi

mkdir -p "$HS_DIR" "$OUT_DIR"
# Every per-domain readout and the host map (#582) go first, by the #581 rule below:
# a domain dropped from TOR_ONION_DOMAINS since the last start must not keep
# announcing its onion, and the gateway must not keep a map this start never wrote.
rm -f "$OUT_DIR"/*.hostname "$MAP_FILE"
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

# One more stanza per Tor domain (#582): its own key, the SAME two upstreams.
if [ -n "$DOMAIN_LINES" ]; then
  mkdir -p "$DOMAIN_HS_ROOT"
  chmod 700 "$DOMAIN_HS_ROOT"
  printf '%s' "$DOMAIN_LINES" | while read -r slug tenant; do
    [ -n "$slug" ] || continue
    mkdir -p "$DOMAIN_HS_ROOT/$slug"
    chmod 700 "$DOMAIN_HS_ROOT/$slug"
    # printf, not a second heredoc: the primary stanza above stays the one literal
    # spelling of each directive (tests/stack/test-tor-flip-wiring.sh mutates it).
    printf '%s\n' "# domain onion '$slug' -> tenant '$tenant' (hugmesh-generator#582)" \
      "HiddenServiceDir $DOMAIN_HS_ROOT/$slug" "HiddenServiceVersion 3" \
      "HiddenServicePort 80 $UPSTREAM" "HiddenServicePort 443 $TLS_UPSTREAM" >> "$TORRC"
  done
  # tor (after `User tor`) must own every key directory it serves.
  chown -R tor:tor "$DOMAIN_HS_ROOT"
fi

# all_minted: the primary key and every domain's key have a hostname.
all_minted() {
  [ -s "$HS_DIR/hostname" ] || return 1
  printf '%s' "$DOMAIN_LINES" | while read -r slug _t; do
    [ -z "$slug" ] || [ -s "$DOMAIN_HS_ROOT/$slug/hostname" ] || exit 1
  done
}

# valid_onion NAME: a v3 onion hostname — 56 base32 characters, then ".onion".
valid_onion() {
  case "$1" in *.onion) ;; *) return 1 ;; esac
  _vo="${1%.onion}"
  case "$_vo" in ''|*[!a-z2-7]*) return 1 ;; esac
  [ "${#_vo}" -eq 56 ]
}

# write_map: the gateway host map (hugmesh-gateway#38), temp-then-rename in the SAME
# directory. The primary as `default`, then each minted domain onion as its tenant.
# Nothing at all when the map directory is not mounted (a stack with no Tor domain).
write_map() {
  [ -d "$MAP_DIR" ] || return 0
  primary="$(tr -d '[:space:]' < "$HS_DIR/hostname")"
  valid_onion "$primary" || return 1
  tmp="$MAP_DIR/.onion-hosts.map.$$"
  {
    echo "# written by hugmesh-tor (tests/stack/tor/entrypoint.sh), hugmesh-generator#582"
    echo "${primary}=default"
    printf '%s' "$DOMAIN_LINES" | while read -r slug tenant; do
      [ -n "$slug" ] && [ -s "$DOMAIN_HS_ROOT/$slug/hostname" ] || continue
      name="$(tr -d '[:space:]' < "$DOMAIN_HS_ROOT/$slug/hostname")"
      valid_onion "$name" || continue
      echo "${name}=${tenant}"
    done
  } > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$MAP_FILE"
}

# Publish the hostnames out once tor mints them (first boot ~1s; already present on a
# restart). The hostnames are PUBLIC; only the keys stay inside the named volumes.
# ORDER MATTERS: the host map, then every domain's readout, then the primary's LAST —
# the healthcheck and every reader key off the primary, so "published" means the
# domains and the map are already in place.
(
  i=0
  while ! all_minted && [ "$i" -lt 120 ]; do sleep 1; i=$((i + 1)); done
  if [ -s "$HS_DIR/hostname" ]; then
    write_map || echo "[hugmesh-tor] WARNING: the gateway host map could not be written to $MAP_FILE" >&2
    printf '%s' "$DOMAIN_LINES" | while read -r slug tenant; do
      [ -n "$slug" ] || continue
      if [ -s "$DOMAIN_HS_ROOT/$slug/hostname" ]; then
        cp "$DOMAIN_HS_ROOT/$slug/hostname" "$OUT_DIR/$slug.hostname"
        chmod 644 "$OUT_DIR/$slug.hostname" 2>/dev/null || true
        echo "[hugmesh-tor] domain onion '${slug}' (tenant '${tenant}') published -> $(cat "$OUT_DIR/$slug.hostname")"
      else
        echo "[hugmesh-tor] WARNING: domain onion '${slug}' not minted within 120s" >&2
      fi
    done
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
  rm -f "$OUT_DIR/hostname" "$OUT_DIR"/*.hostname "$MAP_FILE"
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

#!/usr/bin/env bash
#
# tor-onion-e2e.sh — End-to-end proof that a Tor v3 onion (hidden) service exposes
# a local HTTP backend and is reachable over the LIVE Tor network, using the exact
# mechanism Tor Browser uses (Tor's own SOCKS proxy + an onion HTTP fetch).
#
# This is the MECHANISM proof behind two features that both publish a v3 .onion:
#   - the OPT-IN local-mesh `snapdragon-tor` service (tests/stack/tor/, `TOR=1`);
#   - the NODE `tor` optional service + the `tor-onion` go-live provider
#     (docs/TOR-HIDDEN-SERVICE.md).
# Both rely on: torrc HiddenServiceDir/HiddenServicePort -> a v3 .onion whose
# descriptor tor uploads to the network, reachable via any Tor client. This script
# reproduces exactly that, standalone, with the host tor daemon — no docker, no
# root, no system services touched.
#
# What it does, idempotently:
#   1. Writes a marker index page into a webroot with a unique string.
#   2. Starts a local HTTP backend  (python3 -m http.server, bound to loopback).
#   3. Writes a torrc that maps  <onion>:80 -> 127.0.0.1:<backend port>.
#   4. Launches the host tor daemon, waits for it to bootstrap to 100% and to
#      publish the v3 service descriptor.
#   5. Fetches http://<onion>/ through Tor's SOCKS5 proxy (curl
#      --socks5-hostname, which resolves + connects the .onion inside Tor,
#      identical to a Tor Browser request) and asserts the marker is returned.
#   6. Prints the .onion address and timings, then tears everything down.
#
# Exit status: 0 ONLY if the onion fetch returned our exact marker string.
#
# No root, no docker, no system services touched. Everything runs as the invoking
# user inside a self-contained work directory and is cleaned up on exit (success,
# failure, or Ctrl-C) via a trap.
#
# Tunables (environment variables, all optional):
#   WORKDIR      Working directory (default: a fresh mktemp dir, removed on exit
#                unless KEEP_WORKDIR=1). Never writes into the repo tree.
#   SOCKS_PORT   Tor SOCKS proxy port           (default 39050)
#   BACKEND_PORT Local HTTP backend port        (default 39080)
#   TOR_BIN      Path to the tor binary         (default: /usr/bin/tor, else PATH)
#   BOOT_TIMEOUT Seconds to wait for hostname+bootstrap (default 120)
#   FETCH_TRIES  Onion fetch attempts           (default 20)
#   FETCH_SLEEP  Seconds between fetch attempts (default 6)
#   FETCH_MAXTIME Per-curl --max-time seconds   (default 90)
#   KEEP_KEYS    If 1, keep HiddenServiceDir keys so the .onion is stable
#                across runs (default: unset -> fresh onion every run).
#
set -u -o pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Default WORKDIR is a fresh temp dir so the harness NEVER writes into the repo
# tree (and, under the pytest wrapper, WORKDIR is a pytest tmp_path). Removed on
# exit unless KEEP_WORKDIR=1 or an external WORKDIR was supplied.
_WE_MADE_WORKDIR=""
if [ -z "${WORKDIR:-}" ]; then
    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/snapdragon-onion-e2e.XXXXXX")"
    _WE_MADE_WORKDIR=1
fi
SOCKS_PORT="${SOCKS_PORT:-39050}"
BACKEND_PORT="${BACKEND_PORT:-39080}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-120}"
FETCH_TRIES="${FETCH_TRIES:-20}"
FETCH_SLEEP="${FETCH_SLEEP:-6}"
FETCH_MAXTIME="${FETCH_MAXTIME:-90}"

# Locate the tor binary (prefer the explicit host path).
TOR_BIN="${TOR_BIN:-/usr/bin/tor}"
if [ ! -x "$TOR_BIN" ]; then
    TOR_BIN="$(command -v tor || true)"
fi

# Derived paths.
HS_DIR="${WORKDIR}/hs"
TOR_DATA="${WORKDIR}/tordata"
WEBROOT="${WORKDIR}/webroot"
TORRC="${WORKDIR}/torrc"
TOR_LOG="${WORKDIR}/tor.log"

# A unique, greppable marker so a match cannot be a coincidence.
MARKER="SNAPDRAGON-ONION-E2E-OK-$(date +%s)-${RANDOM}${RANDOM}"

# PIDs of the processes we start (for cleanup).
HTTP_PID=""
TOR_PID=""

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Cleanup — always runs (EXIT trap). Kills anything we started and reports
# whether the work dir is process-clean.
# ---------------------------------------------------------------------------
cleanup() {
    local rc=$?
    log "cleanup: tearing down (exit code so far: ${rc})"
    if [ -n "${TOR_PID}" ] && kill -0 "${TOR_PID}" 2>/dev/null; then
        kill "${TOR_PID}" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "${TOR_PID}" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "${TOR_PID}" 2>/dev/null || true
        log "cleanup: tor (pid ${TOR_PID}) stopped"
    fi
    if [ -n "${HTTP_PID}" ] && kill -0 "${HTTP_PID}" 2>/dev/null; then
        kill "${HTTP_PID}" 2>/dev/null || true
        for _ in 1 2 3 4 5 6; do
            kill -0 "${HTTP_PID}" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "${HTTP_PID}" 2>/dev/null || true
        log "cleanup: http backend (pid ${HTTP_PID}) stopped"
    fi
    # Remove the work dir only if WE created it (a fresh mktemp) and KEEP_WORKDIR
    # is not set — never delete an operator-supplied WORKDIR.
    if [ -n "${_WE_MADE_WORKDIR}" ] && [ "${KEEP_WORKDIR:-0}" != "1" ]; then
        rm -rf "${WORKDIR}" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
[ -n "${TOR_BIN}" ] && [ -x "${TOR_BIN}" ] || fail "tor binary not found/executable (set TOR_BIN=)"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v curl    >/dev/null 2>&1 || fail "curl not found"

# Refuse to run if the ports we want are already occupied — avoids clobbering
# and misleading results. Uses bash's /dev/tcp (no external deps).
port_busy() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
    return 1
}
port_busy "${SOCKS_PORT}"   && fail "SOCKS port ${SOCKS_PORT} already in use — pick another via SOCKS_PORT="
port_busy "${BACKEND_PORT}" && fail "backend port ${BACKEND_PORT} already in use — pick another via BACKEND_PORT="

# ---------------------------------------------------------------------------
# 1. Fresh work dir + marker page
# ---------------------------------------------------------------------------
if [ "${KEEP_KEYS:-0}" = "1" ] && [ -d "${HS_DIR}" ]; then
    # Preserve the onion key material, wipe everything else.
    log "KEEP_KEYS=1: preserving existing HiddenServiceDir keys"
    rm -rf "${TOR_DATA}" "${WEBROOT}" "${TORRC}" "${TOR_LOG}"
else
    rm -rf "${HS_DIR}" "${TOR_DATA}" "${WEBROOT}" "${TORRC}" "${TOR_LOG}"
fi
mkdir -p "${HS_DIR}" "${TOR_DATA}" "${WEBROOT}"

# tor refuses to use a HiddenServiceDir that is group/other-accessible.
chmod 0700 "${HS_DIR}" "${TOR_DATA}"

cat > "${WEBROOT}/index.html" <<EOF
<!doctype html>
<html><head><title>Snapdragon onion e2e</title></head>
<body><h1>${MARKER}</h1>
<p>Served by a local HTTP backend, reached over Tor as a v3 onion service.</p>
</body></html>
EOF
log "marker string: ${MARKER}"

# ---------------------------------------------------------------------------
# 2. Local HTTP backend (loopback only)
# ---------------------------------------------------------------------------
python3 -m http.server "${BACKEND_PORT}" --bind 127.0.0.1 --directory "${WEBROOT}" \
    > "${WORKDIR}/http.log" 2>&1 &
HTTP_PID=$!
log "http backend started (pid ${HTTP_PID}) on 127.0.0.1:${BACKEND_PORT}"

# Confirm the backend actually serves the marker locally before involving Tor,
# so a later onion failure can't be blamed on the backend.
backend_ok=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS --max-time 5 "http://127.0.0.1:${BACKEND_PORT}/" 2>/dev/null | grep -q "${MARKER}"; then
        backend_ok=1; break
    fi
    kill -0 "${HTTP_PID}" 2>/dev/null || fail "http backend died on startup (see ${WORKDIR}/http.log)"
    sleep 0.5
done
[ -n "${backend_ok}" ] || fail "local backend never served the marker on 127.0.0.1:${BACKEND_PORT}"
log "local backend verified serving the marker"

# ---------------------------------------------------------------------------
# 3. torrc
# ---------------------------------------------------------------------------
cat > "${TORRC}" <<EOF
# Auto-generated by tor-onion-e2e.sh — self-contained, no system config.
DataDirectory ${TOR_DATA}
SocksPort 127.0.0.1:${SOCKS_PORT}
HiddenServiceDir ${HS_DIR}
HiddenServiceVersion 3
HiddenServicePort 80 127.0.0.1:${BACKEND_PORT}
Log notice file ${TOR_LOG}
# Keep this instance from clashing with a system tor / consuming a control port.
ControlPort 0
EOF
log "wrote torrc -> ${TORRC}"

# ---------------------------------------------------------------------------
# 4. Launch tor and wait for hostname + bootstrap
# ---------------------------------------------------------------------------
T0=$(date +%s)
"${TOR_BIN}" -f "${TORRC}" > "${WORKDIR}/tor.stdout.log" 2>&1 &
TOR_PID=$!
log "tor launched (pid ${TOR_PID}) using ${TOR_BIN}"

t_hostname=""      # seconds from launch to hostname file appearing
t_bootstrapped=""  # seconds from launch to "Bootstrapped 100%"
ONION=""

deadline=$(( T0 + BOOT_TIMEOUT ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
    kill -0 "${TOR_PID}" 2>/dev/null || fail "tor process exited early (see ${TOR_LOG} / tor.stdout.log)"

    if [ -z "${ONION}" ] && [ -s "${HS_DIR}/hostname" ]; then
        ONION="$(tr -d '[:space:]' < "${HS_DIR}/hostname")"
        t_hostname=$(( $(date +%s) - T0 ))
        log "hostname minted after ${t_hostname}s: ${ONION}"
    fi
    if [ -z "${t_bootstrapped}" ] && [ -f "${TOR_LOG}" ] && grep -q "Bootstrapped 100%" "${TOR_LOG}"; then
        t_bootstrapped=$(( $(date +%s) - T0 ))
        log "tor bootstrapped 100% after ${t_bootstrapped}s"
    fi

    # Ready to attempt fetching once we have both the onion name and a fully
    # bootstrapped tor. Descriptor upload usually lands within a few more secs.
    if [ -n "${ONION}" ] && [ -n "${t_bootstrapped}" ]; then
        break
    fi
    sleep 1
done

[ -n "${ONION}" ]         || fail "no hostname file after ${BOOT_TIMEOUT}s (see ${TOR_LOG})"
[ -n "${t_bootstrapped}" ] || fail "tor did not reach Bootstrapped 100% within ${BOOT_TIMEOUT}s (see ${TOR_LOG})"

# Informational: note service-side descriptor / circuit establishment lines.
if grep -Eq "Tor has successfully opened a circuit|uploaded .*descriptor|Uploaded rendezvous|Service .* descriptor" "${TOR_LOG}"; then
    log "tor log shows circuit/descriptor establishment"
fi

# ---------------------------------------------------------------------------
# 5. Fetch the onion through Tor's SOCKS proxy and assert the marker.
#    curl --socks5-hostname resolves + connects the .onion *inside* Tor,
#    exactly as Tor Browser does. Descriptor propagation to the HSDir ring
#    can take 20-60s, so we retry.
# ---------------------------------------------------------------------------
log "fetching http://${ONION}/ via SOCKS 127.0.0.1:${SOCKS_PORT} (up to ${FETCH_TRIES} tries)"
body=""
t_fetched=""
for i in $(seq 1 "${FETCH_TRIES}"); do
    kill -0 "${TOR_PID}" 2>/dev/null || fail "tor died during fetch phase"
    body="$(curl -sS --socks5-hostname "127.0.0.1:${SOCKS_PORT}" \
                 --max-time "${FETCH_MAXTIME}" "http://${ONION}/" 2>/dev/null || true)"
    if printf '%s' "${body}" | grep -q "${MARKER}"; then
        t_fetched=$(( $(date +%s) - T0 ))
        log "onion fetch SUCCEEDED on attempt ${i} (marker matched) after ${t_fetched}s from launch"
        break
    fi
    log "attempt ${i}/${FETCH_TRIES}: marker not yet returned; retrying in ${FETCH_SLEEP}s"
    sleep "${FETCH_SLEEP}"
done

# ---------------------------------------------------------------------------
# 6. Report
# ---------------------------------------------------------------------------
if [ -n "${t_fetched}" ]; then
    echo "======================================================================"
    echo "RESULT:            SUCCESS (marker returned over Tor)"
    echo "Onion address:     ${ONION}"
    echo "Marker:            ${MARKER}"
    echo "tor version:       $(${TOR_BIN} --version 2>/dev/null | head -1)"
    echo "launch -> hostname:      ${t_hostname}s"
    echo "launch -> bootstrap100:  ${t_bootstrapped}s"
    echo "launch -> first fetch:   ${t_fetched}s"
    echo "======================================================================"
    exit 0
else
    echo "======================================================================"
    echo "RESULT:            FAILURE (onion never returned the marker)"
    echo "Onion address:     ${ONION}"
    echo "Last response body (truncated):"
    printf '%s\n' "${body}" | head -20
    echo "See tor log: ${TOR_LOG}"
    echo "======================================================================"
    exit 1
fi

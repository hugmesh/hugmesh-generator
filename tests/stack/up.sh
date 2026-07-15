#!/usr/bin/env bash
# up.sh — bring up the rootless integration stack: generated TLS certs +
# mock Matrix + mock Mastodon + the built Angular host served over HTTPS.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="${HERE}/.run"; mkdir -p "${RUN}"
CERTS="${HERE}/certs"
UI_DIST="${UI_DIST:-${HERE}/.uidist}"
MATRIX_PORT="${MATRIX_PORT:-8401}"; MASTODON_PORT="${MASTODON_PORT:-8402}"; BFF_PORT="${BFF_PORT:-8403}"; UI_PORT="${UI_PORT:-8443}"
# REAL_MATRIX=1 routes the UI's /_matrix to the real Synapse (tests/stack
# brings it up) and mock-bff.mjs brokers real Synapse tokens against it — the
# BFF itself stays mock-bff.mjs either way (this never runs a real Spring
# BFF/gateway; for that use `make stack-up`, see docs/LOCAL-STACK.md). Default
# uses the fast in-memory double for Angular UI-unit runs.
SYNAPSE_URL="${SYNAPSE_URL:-http://127.0.0.1:8008}"
if [ "${REAL_MATRIX:-0}" = "1" ]; then MATRIX_TARGET="${SYNAPSE_URL}"; else MATRIX_TARGET="http://127.0.0.1:${MATRIX_PORT}"; fi

[ -f "${CERTS}/server.crt" ] || bash "${HERE}/gen-certs.sh" "${CERTS}"
[ -d "${UI_DIST}" ] || { echo "ERROR: built UI not found at ${UI_DIST}. Build it first (see README)."; exit 1; }

# The host is a native-federation shell; the 4 remotes must be assembled under
# ${UI_DIST}/_remotes/<name>/ (run-all.sh does this). Fail loudly here rather
# than serve 404 chunks at test time.
REMOTES_ROOT="${REMOTES_ROOT:-${UI_DIST}/_remotes}"
for n in login matrix mastodon admin; do
  [ -f "${REMOTES_ROOT}/${n}/remoteEntry.json" ] || {
    echo "ERROR: federation remote '${n}' not assembled at ${REMOTES_ROOT}/${n}/remoteEntry.json"
    echo "       Build + assemble the remotes first: tests/e2e/run-all.sh (step 1)."; exit 1; }
done

start() { # name cmd...
  local name="$1"; shift
  nohup "$@" >"${RUN}/${name}.log" 2>&1 &
  echo $! > "${RUN}/${name}.pid"
  echo "  started ${name} (pid $(cat "${RUN}/${name}.pid"))"
}

echo "==> Starting mock backends + UI"
PORT="${MATRIX_PORT}"   start matrix   node "${HERE}/mock-matrix.mjs"
PORT="${MASTODON_PORT}" start mastodon node "${HERE}/mock-mastodon.mjs"
# The BFF brokers Matrix service tokens against the SAME matrix endpoint the UI
# talks to (MATRIX_TARGET): the in-memory mock-matrix (:8401) by default, or the
# real Synapse when REAL_MATRIX=1. (Previously this always pointed at :8008, so
# in mock mode token brokering hit a dead port and matrix.token came back empty.)
PORT="${BFF_PORT}" ADMIN_EMAILS="${ADMIN_EMAILS:-admin@snapdragon.systems}" \
  SYNAPSE_URL="${MATRIX_TARGET}" MASTODON_URL="http://127.0.0.1:${MASTODON_PORT}" \
  start bff node "${HERE}/mock-bff.mjs"
CERTS="${CERTS}" UI_DIST="${UI_DIST}" PORT="${UI_PORT}" \
  REMOTES_ROOT="${REMOTES_ROOT}" REMOTES="login,matrix,mastodon,admin" \
  MATRIX_TARGET="${MATRIX_TARGET}" MASTODON_TARGET="http://127.0.0.1:${MASTODON_PORT}" \
  BFF_TARGET="http://127.0.0.1:${BFF_PORT}" \
  start ui node "${HERE}/serve-ui.mjs"
echo "  (matrix target: ${MATRIX_TARGET})"

echo "==> Waiting for https://localhost:${UI_PORT}"
for i in $(seq 1 30); do
  if curl -ksf "https://localhost:${UI_PORT}/" >/dev/null 2>&1; then
    echo "  up."
    curl -ksf "https://localhost:${UI_PORT}/assets/federation.manifest.json" >/dev/null 2>&1 \
      && curl -ksf "https://localhost:${UI_PORT}/_remotes/matrix/remoteEntry.json" >/dev/null 2>&1 \
      || echo "  WARN: federation manifest or a remoteEntry is not served — federated routes will fail"
    exit 0
  fi
  sleep 1
done
echo "  WARN: UI did not answer in 30s; see ${RUN}/*.log"; exit 1

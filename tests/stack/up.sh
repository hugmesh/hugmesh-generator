#!/usr/bin/env bash
# up.sh — bring up the rootless integration stack: generated TLS certs +
# mock Matrix + mock Mastodon + the built Angular host served over HTTPS.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="${HERE}/.run"; mkdir -p "${RUN}"
CERTS="${HERE}/certs"
UI_DIST="${UI_DIST:-${HERE}/.uidist}"
MATRIX_PORT="${MATRIX_PORT:-8401}"; MASTODON_PORT="${MASTODON_PORT:-8402}"; BFF_PORT="${BFF_PORT:-8403}"; UI_PORT="${UI_PORT:-8443}"
# REAL_MATRIX=1 routes the UI's /_matrix to the real tuwunel homeserver
# (tests/stack brings it up) and mock-bff.mjs brokers real Matrix tokens
# against it — the BFF itself stays mock-bff.mjs either way (this never runs a
# real Spring BFF/gateway; for that use `make stack-up`, see
# docs/LOCAL-STACK.md). Default uses the fast in-memory double for Angular
# UI-unit runs. (SYNAPSE_URL is the frozen Spring-BFF env-name contract; the
# server behind it is tuwunel.)
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

# The shadows-of-the-net Godot WASM bundle (matrix-ui's chat3d room) is a
# STATIC remote — no remoteEntry.json, never in the federation manifest. It is
# assembled from the sibling hugmesh-games repo's COMMITTED export (the same
# bundle the games stack's wasm-fragment nginx bakes; built there via
# `make build-godot`, preset Shadows-Of-The-Net). Absent bundle = warn and
# serve without it — the chat3d e2e then skips with a precise reason instead
# of failing on a 404 iframe. The copy is gitignored (a ~40MB assemble-time
# artifact, not generator content).
GAMES_REPO="${GAMES_REPO:-${HERE}/../../../hugmesh-games}"
SOTN_SRC="${GAMES_REPO}/backend/src/main/resources/assets/levels/shadows-of-the-net"
if [ -f "${SOTN_SRC}/index.wasm" ]; then
  mkdir -p "${REMOTES_ROOT}/wasm-fragment"
  rm -rf "${REMOTES_ROOT}/wasm-fragment/shadows-of-the-net"
  cp -r "${SOTN_SRC}" "${REMOTES_ROOT}/wasm-fragment/shadows-of-the-net"
  echo "  assembled wasm-fragment/shadows-of-the-net from ${GAMES_REPO}"
else
  echo "  WARN: shadows-of-the-net bundle not found at ${SOTN_SRC} — 3D-room e2e will skip"
  echo "        (build it in hugmesh-games: make build-godot, preset Shadows-Of-The-Net)"
fi

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
# real tuwunel when REAL_MATRIX=1. (Previously this always pointed at :8008, so
# in mock mode token brokering hit a dead port and matrix.token came back empty.)
PORT="${BFF_PORT}" ADMIN_EMAILS="${ADMIN_EMAILS:-admin@hugmesh.systems}" \
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

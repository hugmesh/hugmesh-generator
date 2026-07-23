#!/usr/bin/env bash
# run.sh — run the Playwright suite against an already-running stack, using the
# Playwright docker image (browsers bundled; no host browser install needed).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${PW_IMAGE:-hugmeshgames-e2e:latest}"
BASE_URL="${SNAP_BASE_URL:-https://localhost:8443}"
mkdir -p "${HERE}/screenshots"

# Fallback to a host-local Playwright if the bundled image isn't present.
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "==> Image ${IMAGE} not found; using host npx (run 'npm i && npx playwright install chromium' first)"
  cd "${HERE}" && SNAP_BASE_URL="${BASE_URL}" SNAP_SHOTS="${HERE}/screenshots" \
    npx playwright test -c playwright.config.ts --reporter=list "$@"
  exit $?
fi

exec docker run --rm --network host --ipc=host \
  -v "${HERE}:/work/e2e" -w /work/e2e \
  -e SNAP_BASE_URL="${BASE_URL}" -e SNAP_SHOTS=/work/e2e/screenshots \
  "${IMAGE}" npx playwright test -c playwright.config.ts --reporter=list "$@"

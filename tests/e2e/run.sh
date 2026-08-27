#!/usr/bin/env bash
# run.sh — run the Playwright suite against an already-running stack, using the
# Playwright docker image (browsers bundled; no host browser install needed).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${PW_IMAGE:-hugmeshgames-e2e:latest}"
BASE_URL="${SNAP_BASE_URL:-https://localhost:8443}"
mkdir -p "${HERE}/screenshots"

# RESOLVE, NEVER GENERATE. This lane drives an ALREADY-RUNNING stack, so the
# password must be the one that stack was seeded with — minting a fresh one here
# would simply not match, and every login would fail for a reason nothing names.
# So: env, else the run-state file, else stop and say what to run.
#
# It has to be passed EXPLICITLY into the container. The docker invocation below
# mounts only ${HERE} (tests/e2e) at /work/e2e, so a repo-root .e2e-credentials
# is not visible inside, and the helpers' walk-up from /work/e2e can never reach
# it. The host-npx fallback happens to work via that walk-up; the container path
# does not, and the failure is a throw at module load.
if [ -z "${E2E_PASSWORD:-}" ]; then
  . "${HERE}/../stack/e2e-password.sh"
  E2E_PASSWORD="$(e2e_password_read E2E_PASSWORD)" || exit 1
  export E2E_PASSWORD
fi
if [ -z "${E2E_PASSWORD:-}" ]; then
  echo "run.sh: no e2e password resolved (checked \$E2E_PASSWORD and ${E2E_CREDENTIALS_FILE:-<repo>/.e2e-credentials})." >&2
  echo "  This lane drives an already-running stack, so it will not mint one." >&2
  echo "  Seed the stack first: make stack-seed" >&2
  exit 1
fi

# Fallback to a host-local Playwright if the bundled image isn't present.
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "==> Image ${IMAGE} not found; using host npx (run 'npm i && npx playwright install chromium' first)"
  cd "${HERE}" && SNAP_BASE_URL="${BASE_URL}" SNAP_SHOTS="${HERE}/screenshots" \
    E2E_PASSWORD="${E2E_PASSWORD}" \
    npx playwright test -c playwright.config.ts --reporter=list "$@"
  exit $?
fi

exec docker run --rm --network host --ipc=host \
  -v "${HERE}:/work/e2e" -w /work/e2e \
  -e SNAP_BASE_URL="${BASE_URL}" -e SNAP_SHOTS=/work/e2e/screenshots \
  -e E2E_PASSWORD="${E2E_PASSWORD}" \
  "${IMAGE}" npx playwright test -c playwright.config.ts --reporter=list "$@"

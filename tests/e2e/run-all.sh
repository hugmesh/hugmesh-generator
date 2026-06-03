#!/usr/bin/env bash
# run-all.sh — one-shot: build the UI, bring up the rootless stack (generated
# certs + mock backends), run the Playwright suite, capture screenshots, tear down.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STACK="${REPO}/tests/stack"
E2E="${REPO}/tests/e2e"
UI_REPO="${SOCIAL_UI_REPO:-${REPO}/../snapdragon-social-ui}"   # the Angular host workspace

echo "==> [1/5] Build the Angular host"
if [ -d "${UI_REPO}" ]; then
  ( cd "${UI_REPO}" && [ -d node_modules ] || npm ci || npm install )
  ( cd "${UI_REPO}" && npx ng build host )
  rm -rf "${STACK}/.uidist"; cp -r "${UI_REPO}/dist/host/browser" "${STACK}/.uidist"
else
  echo "   SOCIAL_UI_REPO not found at ${UI_REPO}; expecting a prebuilt ${STACK}/.uidist"
fi

echo "==> [2/5] Generate certs + values"
bash "${STACK}/gen-certs.sh" "${STACK}/certs"

echo "==> [3/5] Bring up the stack"
UI_DIST="${STACK}/.uidist" bash "${STACK}/up.sh"

echo "==> [4/5] Run Playwright"
set +e
bash "${E2E}/run.sh" "$@"
rc=$?
set -e

echo "==> [5/5] Tear down"
bash "${STACK}/down.sh"
echo "screenshots: ${E2E}/screenshots"
exit "${rc}"

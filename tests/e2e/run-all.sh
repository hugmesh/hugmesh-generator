#!/usr/bin/env bash
# run-all.sh — one-shot: build the UI, bring up the rootless stack (generated
# certs + mock backends), run the Playwright suite, capture screenshots, tear down.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STACK="${REPO}/tests/stack"
E2E="${REPO}/tests/e2e"
# The host shell + the Matrix remote both live in snapdragon-matrix-ui (the repo
# carries the `host` and `matrix` ng projects; it was renamed from social-ui).
# mastodon/login/admin are their own native-federation remote repos. NOTE:
# serve-ui.mjs owns the federation manifest for the test stack (synthesizes a
# same-origin one), so the host build's empty assets:[] is intentional here.
# Override with SOCIAL_UI_REPO (or MATRIX_UI_REPO) if your checkout differs.
UI_REPO="${SOCIAL_UI_REPO:-${MATRIX_UI_REPO:-${REPO}/../snapdragon-matrix-ui}}"   # host + matrix
MASTODON_UI_REPO="${MASTODON_UI_REPO:-${REPO}/../snapdragon-mastodon-ui}"
LOGIN_UI_REPO="${LOGIN_UI_REPO:-${REPO}/../snapdragon-login-ui}"
ADMIN_UI_REPO="${ADMIN_UI_REPO:-${REPO}/../snapdragon-admin-ui}"

# build_remote <repo-dir> <ng-project> <remote-name> — build a remote and drop
# its dist/<project>/browser into ${STACK}/.uidist/_remotes/<remote-name>.
build_remote() {
  local repo="$1" proj="$2" name="$3"
  if [ -d "${repo}" ]; then
    ( cd "${repo}" && { [ -d node_modules ] || npm ci || npm install; } && npx ng build "${proj}" )
    rm -rf "${STACK}/.uidist/_remotes/${name}"
    mkdir -p "${STACK}/.uidist/_remotes"
    cp -r "${repo}/dist/${proj}/browser" "${STACK}/.uidist/_remotes/${name}"
  else
    echo "   ${name}: repo not found at ${repo}; expecting a prebuilt ${STACK}/.uidist/_remotes/${name}"
  fi
}

echo "==> [1/5] Build the host + 4 federated remotes, assemble .uidist"
if [ -d "${UI_REPO}" ]; then
  ( cd "${UI_REPO}" && { [ -d node_modules ] || npm ci || npm install; } && npx ng build host && npx ng build matrix )
  rm -rf "${STACK}/.uidist"; cp -r "${UI_REPO}/dist/host/browser" "${STACK}/.uidist"
  mkdir -p "${STACK}/.uidist/_remotes"
  cp -r "${UI_REPO}/dist/matrix/browser" "${STACK}/.uidist/_remotes/matrix"
else
  echo "   SOCIAL_UI_REPO not found at ${UI_REPO}; expecting a prebuilt ${STACK}/.uidist (host + _remotes/matrix)"
fi
build_remote "${MASTODON_UI_REPO}" mastodon mastodon
build_remote "${LOGIN_UI_REPO}"    login    login
build_remote "${ADMIN_UI_REPO}"    admin    admin

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

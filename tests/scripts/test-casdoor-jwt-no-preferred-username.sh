#!/usr/bin/env bash
# test-casdoor-jwt-no-preferred-username.sh — OFFLINE account-takeover regression
# lock for the hugmesh (systems) Casdoor realm. [2026-07-16]
#
# WHAT THIS GUARDS, and WHY it is a security gate (not cosmetics):
#   user-bff historically folded an inbound token's `preferred_username` claim
#   into a `discord:<preferred_username>` identity key, letting a caller who
#   controls that claim collide with / take over another user's account. user-bff
#   PR #124 removes that fold STRUCTURALLY. This test locks the COMPLEMENTARY
#   config-level mitigation that ALSO holds the vector shut today: the platform's
#   hugmesh-realm OAuth2 apps are `tokenFormat=JWT-Custom` with an allow-list
#   (JWT_CUSTOM_TOKEN_FIELDS / JWT_CUSTOM_TOKEN_ATTRIBUTES in
#   specs/cluster/manifests/casdoor/init-job.yaml) that emits the identity as
#   `name` and NEVER serializes a `preferred_username`.
#
#   That omission is INCIDENTAL — the allow-list exists for an unrelated
#   secret-leak fix (D6+D8). If a systems app ever reverts to plain
#   `tokenFormat: JWT` (which serializes the FULL user object incl. a
#   `preferred_username` from casdoor's Name json tag) or someone adds
#   preferred_username to the allow-list to satisfy an OIDC client, the takeover
#   silently re-opens.
#
# This is the CHEAP, ALWAYS-RUNS companion to the held-until-live token-mint test
# tests/casdoor/test-jwt-custom-token.sh (which mints a REAL token and asserts the
# same absence at runtime, but SKIPS on CI boxes without a docker/podman runtime).
# This script is pure static file inspection — no container, no network, no swap.
#
# SCOPE: the `hugmesh` systems realm ONLY (specs/cluster/manifests/casdoor/).
# The `threewizards` games realm (specs/cluster/manifests/casdoor-games/) is a
# SEPARATE realm that deliberately uses plain `tokenFormat: JWT` and is EXEMPT —
# it is not consumed by user-bff's identity-key derivation.
#
# Exit 0 = clean; non-zero = the lock is broken (prints exactly which check).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CASDOOR_DIR="${REPO}/specs/cluster/manifests/casdoor"
INIT_JOB="${CASDOOR_DIR}/init-job.yaml"

P=0; F=0
ok(){  echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== casdoor JWT-Custom no-preferred_username static lock (hugmesh realm) =="

if [ ! -f "${INIT_JOB}" ]; then
  echo "FAIL: ${INIT_JOB} not found (repo layout changed?)"
  exit 1
fi

# The forbidden identifiers, matched case-insensitively. `preferred_username` /
# `preferredUsername` are the OIDC claim itself; `DisplayName` is the casdoor field
# that, if allow-listed, casdoor also serializes into a preferred_username-shaped
# display claim.
FORBIDDEN='preferred_username|preferredUsername|PreferredUsername|DisplayName'

# ---------------------------------------------------------------------------
# Check 1: the JWT_CUSTOM_TOKEN_FIELDS allow-list must not name any forbidden
# identity field. We extract ONLY the `JWT_CUSTOM_TOKEN_FIELDS = [ ... ]` list
# block (up to its closing `]`) so we do NOT false-positive on the ubiquitous
# legit `"displayName": ...` app/provider config keys elsewhere in the file.
# ---------------------------------------------------------------------------
FIELDS_BLOCK="$(awk '/JWT_CUSTOM_TOKEN_FIELDS[[:space:]]*=[[:space:]]*\[/{f=1} f{print} f&&/\]/{f=0}' "${INIT_JOB}")"
if [ -z "${FIELDS_BLOCK}" ]; then
  bad "could not locate the JWT_CUSTOM_TOKEN_FIELDS = [ ... ] block in init-job.yaml"
elif printf '%s\n' "${FIELDS_BLOCK}" | grep -qiE "${FORBIDDEN}"; then
  bad "JWT_CUSTOM_TOKEN_FIELDS names a preferred_username-shaped field -> re-opens the user-bff PR #124 takeover vector:"
  printf '%s\n' "${FIELDS_BLOCK}" | grep -niE "${FORBIDDEN}" | sed 's/^/         /'
else
  ok "JWT_CUSTOM_TOKEN_FIELDS carries no preferred_username/DisplayName field"
  # Positive assertion: `Name` IS the identity field in the allow-list.
  if printf '%s\n' "${FIELDS_BLOCK}" | grep -qE '"Name"'; then
    ok "JWT_CUSTOM_TOKEN_FIELDS carries the Name identity field (emits the name claim)"
  else
    bad "JWT_CUSTOM_TOKEN_FIELDS is missing the \"Name\" identity field — allow-list shape changed"
  fi
fi

# ---------------------------------------------------------------------------
# Check 2: the JWT_CUSTOM_TOKEN_ATTRIBUTES list must not add a preferred_username
# claim via an Existing-Field mapping either.
# ---------------------------------------------------------------------------
ATTRS_BLOCK="$(awk '/JWT_CUSTOM_TOKEN_ATTRIBUTES[[:space:]]*=[[:space:]]*\[/{f=1} f{print} f&&/\]/{f=0}' "${INIT_JOB}")"
if [ -z "${ATTRS_BLOCK}" ]; then
  bad "could not locate the JWT_CUSTOM_TOKEN_ATTRIBUTES = [ ... ] block in init-job.yaml"
elif printf '%s\n' "${ATTRS_BLOCK}" | grep -qiE "${FORBIDDEN}"; then
  bad "JWT_CUSTOM_TOKEN_ATTRIBUTES adds a preferred_username-shaped claim:"
  printf '%s\n' "${ATTRS_BLOCK}" | grep -niE "${FORBIDDEN}" | sed 's/^/         /'
else
  ok "JWT_CUSTOM_TOKEN_ATTRIBUTES adds no preferred_username-shaped claim"
fi

# ---------------------------------------------------------------------------
# Check 3: NO hugmesh-realm app may use plain `tokenFormat: JWT` (which would
# serialize the full user object incl. preferred_username AND the secrets D6+D8
# strips). Only `JWT-Custom` is allowed here. The value pattern `"JWT"` (closing
# quote right after JWT) matches plain JWT and does NOT match `"JWT-Custom"`.
# Scoped to specs/cluster/manifests/casdoor/ — the games realm is exempt.
# ---------------------------------------------------------------------------
PLAIN_JWT="$(grep -rnE '"tokenFormat"[[:space:]]*:[[:space:]]*"JWT"' "${CASDOOR_DIR}" 2>/dev/null || true)"
if [ -n "${PLAIN_JWT}" ]; then
  bad "a hugmesh-realm app uses plain tokenFormat=JWT (full-user serialization re-opens preferred_username + the D6+D8 secret leak):"
  printf '%s\n' "${PLAIN_JWT}" | sed 's/^/         /'
else
  ok "no hugmesh-realm app uses plain tokenFormat=JWT (JWT-Custom allow-list intact)"
fi

echo ""
echo "== summary: ${P} pass / ${F} fail =="
[ "${F}" -eq 0 ] || exit 1

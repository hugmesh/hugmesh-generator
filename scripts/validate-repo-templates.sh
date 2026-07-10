#!/usr/bin/env bash
# ============================================================================
# validate-repo-templates.sh — archetype-overlay DRIFT guard (mesh templating).
# ============================================================================
#
# Sibling to scripts/validate-reserved-prefixes.sh: a fail-loud drift check wired
# for CI. Phase 4 generalizes it from the per-repo whole-file byte-compare to an
# ANCHORED-REGION compare against an ARCHETYPE overlay — because a 2nd class member
# (e.g. user-bff vs the admin-bff exemplar) legitimately differs from the exemplar
# in the non-brand parts of its files, so only the recipe-touched regions (+ any
# class-A whole-file overlays) are asserted. See scripts/tooling/validate-archetype.js:
#   * recipe anchors: find@upstream still present in base + replace@upstream==find
#     (round-trip no-op);
#   * class-A .hbs (angular-mfe/federation-base.js): render@upstream byte-identical.
#
# The UPSTREAM-IDENTITY token values come from templates/archetypes/<archetype>/
# _identity.env (the drift oracle; whatever KEY=VALUEs it declares are the token
# set — generalized, not forked per repo).
#
# GREEN on a fresh, in-sync base; RED on any injected drift.
#
# Usage:
#   scripts/validate-repo-templates.sh --archetype spring-bff [--repo user-bff-api] [--base DIR]
#
# --base DIR forces a specific read-only base; otherwise pull-repo-base.sh resolves
# it from --repo (set <NAME>_BASE_DIR to point at a present clone). BUILD-HOST ONLY.
set -euo pipefail

_die() { echo "[validate-repo-templates] FATAL: $*" >&2; exit 2; }
_log() { echo "[validate-repo-templates] $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLING="${SCRIPT_DIR}/tooling"

ARCHETYPE=""
REPO=""
BASE_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archetype) ARCHETYPE="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --base)      BASE_OVERRIDE="$2"; shift 2 ;;
    *) _die "unknown argument: $1" ;;
  esac
done

[[ -n "$ARCHETYPE" ]] || _die "missing --archetype (spring-bff|angular-mfe|gateway)"
[[ "$ARCHETYPE" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || _die "invalid --archetype '$ARCHETYPE'"
ARCH_DIR="${REPO_ROOT}/templates/archetypes/${ARCHETYPE}"
[[ -d "$ARCH_DIR" ]] || _die "no archetype overlay '${ARCHETYPE}' at ${ARCH_DIR}"
IDENTITY="${ARCH_DIR}/_identity.env"
[[ -f "$IDENTITY" ]] || _die "missing upstream-identity map: ${IDENTITY}"
# Default the resolving repo to the archetype's exemplar member when not given.
if [[ -z "$REPO" ]]; then
  case "$ARCHETYPE" in
    spring-bff)   REPO="admin-bff-api" ;;
    angular-mfe)  REPO="login-ui" ;;
    gateway)      REPO="gateway" ;;
    *) _die "no default exemplar repo for archetype '${ARCHETYPE}' — pass --repo" ;;
  esac
fi
[[ "$REPO" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || _die "invalid --repo '$REPO'"

command -v node >/dev/null 2>&1 || _die "node not found (build-host tool)"
[[ -d "${TOOLING}/node_modules/handlebars" ]] || _die "handlebars not installed — (cd ${TOOLING} && npm install)"

# ── Resolve a FRESHLY-pulled read-only base ─────────────────────────────────
if [[ -n "$BASE_OVERRIDE" ]]; then
  [[ -d "$BASE_OVERRIDE" ]] || _die "--base '${BASE_OVERRIDE}' is not a directory"
  BASE="$(cd "$BASE_OVERRIDE" && pwd)"
else
  BASE="$("${SCRIPT_DIR}/pull-repo-base.sh" "$REPO")" || _die "could not pull a base for '${REPO}'"
fi
_log "validating archetype '${ARCHETYPE}' (via repo '${REPO}') against base: ${BASE}"

# ── Load the upstream-identity token values (the drift oracle) ──────────────
# GENERALIZED: the token set is whatever KEY=VALUE names _identity.env declares.
# We parse the declared KEYs, source+export each, and build --extra-tokens from the
# SAME set, so a new archetype needs only its _identity.env. render/validate still
# fail-closes each name through the classifier (allow/deny/frozen).
IDENTITY_KEYS=$(grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$IDENTITY" | sed 's/[[:space:]]//g; s/=$//' | sort -u)
[[ -n "$IDENTITY_KEYS" ]] || _die "no KEY=VALUE token declarations in ${IDENTITY}"
# shellcheck source=/dev/null
source "$IDENTITY"
EXTRA_TOKENS=""
for _k in $IDENTITY_KEYS; do
  [[ -n "${!_k:-}" ]] || _die "_identity.env declares '${_k}' but it is empty"
  export "${_k?}"
  EXTRA_TOKENS="${EXTRA_TOKENS:+${EXTRA_TOKENS},}${_k}"
done
_log "drift oracle tokens: ${EXTRA_TOKENS}"

exec node "${TOOLING}/validate-archetype.js" \
  --archetype-dir "$ARCH_DIR" --base "$BASE" --extra-tokens "$EXTRA_TOKENS"

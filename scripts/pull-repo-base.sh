#!/usr/bin/env bash
# ============================================================================
# pull-repo-base.sh — fetch the READ-ONLY Tier-2 base for a templated repo.
# ============================================================================
#
# Mesh repo-templating (Phase 2). Overlay-primary, skeleton-fallback: the base
# repo is the fuller RUNNING code that the thin Tier-1 overlay
# (templates/repos/<name>/) is applied ONTO. This helper resolves that base and
# prints its path to STDOUT (all logs go to STDERR) so callers can do:
#
#     BASE="$(scripts/pull-repo-base.sh login-ui)" || exit 1
#
# HARD RULE: the base is READ-ONLY and is NEVER copied/vendored/committed into the
# generator tree. render_repo_tree overlays it into a separate OUT dir; the base
# clone lives in a gitignored cache (default ./.repo-base) or an out-of-tree path.
#
# Mirrors the clone-all-repos.sh idiom (GIT_BASE knob defaulting to GitHub).
#
# Env knobs:
#   GIT_BASE         (default https://github.com/Snapdragon-Systems)  clone base URL.
#                    Point at the internal mirror on the VPN, e.g.
#                    GIT_BASE=https://gitlab.snapdragon.systems/snapdragon
#   GIT_REF          (default main)  branch/tag to check out.
#   REPO_BASE_CACHE  (default <repo-root>/.repo-base)  gitignored clone cache.
#   LOGIN_UI_BASE_DIR / <NAME>_BASE_DIR   if set to an existing dir, that local
#                    read-only clone is used AS-IS (no fetch). Used by this pilot
#                    to point at the already-present base clone. NAME is the repo
#                    short name upper-cased with '-' -> '_'  (login-ui -> LOGIN_UI).
#   OFFLINE          (default 0)  "1" forbids any network fetch; only a present
#                    cache or a *_BASE_DIR override is accepted (else non-zero).
#
# Exit: 0 + base path on stdout; non-zero (base path absent) on failure. A caller
# that wants the skeleton fallback treats non-zero as "base absent" and proceeds.
set -euo pipefail

log() { echo "[pull-repo-base] $*" >&2; }
die() { echo "[pull-repo-base] FATAL: $*" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"

GIT_BASE="${GIT_BASE:-https://github.com/Snapdragon-Systems}"
GIT_REF="${GIT_REF:-main}"
REPO_BASE_CACHE="${REPO_BASE_CACHE:-${REPO_ROOT}/.repo-base}"
OFFLINE="${OFFLINE:-0}"

[[ $# -eq 1 ]] || die "usage: $0 <repo-short-name>   (e.g. login-ui)"
NAME="$1"
# Slug allowlist: DNS-label-ish short name, so it is safe as a path component and
# as an env-var suffix. (login-ui, admin-bff-api, …)
[[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
  || die "invalid repo short name '${NAME}' (want a DNS label)"

REPO="snapdragon-${NAME}"

# 1) Explicit local read-only base override (this pilot points at the present clone).
ENV_KEY="$(printf '%s' "$NAME" | tr 'a-z-' 'A-Z_')_BASE_DIR"
OVERRIDE="${!ENV_KEY:-}"
if [[ -n "$OVERRIDE" ]]; then
  [[ -d "$OVERRIDE" ]] || die "${ENV_KEY}='${OVERRIDE}' is not a directory"
  abs="$(cd "$OVERRIDE" && pwd)"
  log "using local read-only base for ${REPO}: ${abs} (via ${ENV_KEY}); NOT fetched, NOT copied into the generator"
  printf '%s\n' "$abs"
  exit 0
fi

# 2) Present cache clone — reuse (fast-forward when online, use as-is when offline).
CLONE_DIR="${REPO_BASE_CACHE}/${REPO}"
if [[ -d "${CLONE_DIR}/.git" ]]; then
  if [[ "$OFFLINE" == "1" ]]; then
    log "offline: reusing cached base ${CLONE_DIR} as-is"
  else
    log "updating cached base ${CLONE_DIR} (fetch ${GIT_REF})"
    git -C "$CLONE_DIR" fetch --depth 1 origin "$GIT_REF" >&2 2>&1 \
      || log "warning: fetch failed; using cached base as-is"
    git -C "$CLONE_DIR" checkout -q "$GIT_REF" 2>/dev/null || true
    git -C "$CLONE_DIR" reset -q --hard "origin/${GIT_REF}" 2>/dev/null || true
  fi
  printf '%s\n' "$CLONE_DIR"
  exit 0
fi

# 3) No override, no cache — fetch (unless OFFLINE).
if [[ "$OFFLINE" == "1" ]]; then
  die "offline and no base present for ${REPO} (no *_BASE_DIR override, no cache at ${CLONE_DIR})"
fi
command -v git >/dev/null 2>&1 || die "git not found"
mkdir -p "$REPO_BASE_CACHE"
log "cloning read-only base ${GIT_BASE}/${REPO}.git @ ${GIT_REF} -> ${CLONE_DIR}"
git clone --depth 1 --branch "$GIT_REF" "${GIT_BASE}/${REPO}.git" "$CLONE_DIR" >&2 2>&1 \
  || die "clone failed for ${GIT_BASE}/${REPO}.git (base absent — caller may fall back to skeleton)"
printf '%s\n' "$CLONE_DIR"
exit 0

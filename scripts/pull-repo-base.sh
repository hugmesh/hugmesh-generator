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
# ── FOREIGN-MESH MODE (Phase 7) ──────────────────────────────────────────────
#   pull-repo-base.sh --foreign --mesh <mesh-id> [--pinned-digest SHA] \
#       [--trust-store DIR] [--min-generation N] <repo-short-name>
#   (or FOREIGN_MESH=<mesh-id> env instead of --foreign --mesh)
#
# A base pulled from a FOREIGN mesh is fully hostile until proven: this mode
# REQUIRES scripts/ingest-foreign-base.sh to PASS (digest-pin, pinned-key
# Ed25519 signature — NO trust-on-first-use, SBOM, offline vuln floor, whole-tree
# secret scan, frozen-constant screen, symlink/traversal containment) and prints
# the gate's ADMITTED quarantine snapshot path — NEVER the raw fetched tree. Any
# gate failure exits non-zero with NOTHING on stdout (the raw tree is never
# handed to a caller; a rejected base is admitted nowhere, pushed onward never).
# The skeleton-fallback contract does NOT soften this: a caller asking for a
# declared-foreign base either gets a VERIFIED snapshot or an error.
#
# Per-mesh admission policy comes from templates/mesh-trust/registry.json
# (MESH_REGISTRY env overrides): enabled flag, gitBase (the foreign forge),
# pinnedDigest, minGeneration. --pinned-digest / --min-generation override the
# registry row (an explicit operator act); an unknown or disabled mesh fails
# closed. Trust-store pubkeys are staged out-of-band under keys-template/
# mesh-trust/<mesh-id>/ (MESH_TRUST_STORE / --trust-store overrides).
# OFFLINE=1 is honored: no network fetch — only a *_BASE_DIR override or a
# present foreign cache is accepted as the RAW source (the gate always runs).
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

# Phase 7 foreign-mesh knobs (flags below override; FOREIGN_MESH env implies --foreign).
FOREIGN=0
FOREIGN_MESH="${FOREIGN_MESH:-}"
[[ -n "$FOREIGN_MESH" ]] && FOREIGN=1
PINNED_DIGEST="${FOREIGN_PINNED_DIGEST:-}"
MIN_GENERATION="${FOREIGN_MIN_GENERATION:-}"
MESH_TRUST_STORE="${MESH_TRUST_STORE:-${REPO_ROOT}/keys-template/mesh-trust}"
MESH_REGISTRY="${MESH_REGISTRY:-${REPO_ROOT}/templates/mesh-trust/registry.json}"

NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --foreign)        FOREIGN=1; shift ;;
    --mesh)           FOREIGN=1; FOREIGN_MESH="$2"; shift 2 ;;
    --pinned-digest)  PINNED_DIGEST="$2"; shift 2 ;;
    --trust-store)    MESH_TRUST_STORE="$2"; shift 2 ;;
    --min-generation) MIN_GENERATION="$2"; shift 2 ;;
    -*) die "unknown flag '$1' (usage: $0 [--foreign --mesh ID [--pinned-digest SHA] [--trust-store DIR] [--min-generation N]] <repo-short-name>)" ;;
    *)  [[ -z "$NAME" ]] || die "exactly one <repo-short-name> expected (got '${NAME}' and '$1')"
        NAME="$1"; shift ;;
  esac
done
[[ -n "$NAME" ]] || die "usage: $0 [--foreign --mesh ID ...] <repo-short-name>   (e.g. login-ui)"
# Slug allowlist: DNS-label-ish short name, so it is safe as a path component and
# as an env-var suffix. (login-ui, admin-bff-api, …)
[[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
  || die "invalid repo short name '${NAME}' (want a DNS label)"

REPO="snapdragon-${NAME}"

# ════════════════════════════════════════════════════════════════════════════
# FOREIGN-MESH MODE — resolve the RAW foreign tree, then REQUIRE the inbound
# ingestion gate to PASS. Prints ONLY the gate's admitted quarantine snapshot.
# The trusted-own-mesh path below is untouched (this block exits either way).
# ════════════════════════════════════════════════════════════════════════════
if [[ "$FOREIGN" -eq 1 ]]; then
  [[ -n "$FOREIGN_MESH" ]] || die "--foreign requires --mesh <mesh-id> (or FOREIGN_MESH env)"
  [[ "$FOREIGN_MESH" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
    || die "invalid foreign mesh id '${FOREIGN_MESH}' (must be a DNS label)"
  command -v jq >/dev/null 2>&1 || die "jq not found (mesh registry parse) — fail-closed"

  # Per-mesh admission policy row (explicit trust — an unknown/disabled mesh is
  # NEVER admitted; adding a row + staging its pubkey is a deliberate act).
  [[ -f "$MESH_REGISTRY" ]] || die "mesh registry ${MESH_REGISTRY} absent — no foreign mesh is admissible"
  row="$(jq -e --arg m "$FOREIGN_MESH" '.meshes[$m]' "$MESH_REGISTRY" 2>/dev/null)" \
    || die "mesh '${FOREIGN_MESH}' has NO entry in ${MESH_REGISTRY} — unknown mesh, fail-closed (no trust-on-first-use)"
  [[ "$(jq -r '.enabled // false' <<<"$row")" == "true" ]] \
    || die "mesh '${FOREIGN_MESH}' is not enabled in ${MESH_REGISTRY} — refusing"
  # Registry row supplies defaults; explicit --pinned-digest/--min-generation win.
  [[ -n "$PINNED_DIGEST" ]]  || PINNED_DIGEST="$(jq -r '.pinnedDigest // empty' <<<"$row")"
  [[ -n "$MIN_GENERATION" ]] || MIN_GENERATION="$(jq -r '.minGeneration // 0' <<<"$row")"
  FOREIGN_GIT_BASE="${FOREIGN_GIT_BASE:-$(jq -r '.gitBase // empty' <<<"$row")}"
  # Refuse a mutable ref BEFORE any fetch (the gate re-checks; this stops the
  # network pull itself from ever chasing a moving ref).
  [[ "$PINNED_DIGEST" =~ ^[0-9a-f]{40}$ || "$PINNED_DIGEST" =~ ^[0-9a-f]{64}$ ]] \
    || die "foreign pin '${PINNED_DIGEST:-<empty>}' is not a 40/64-hex immutable digest (mutable refs are refused for foreign bases)"
  [[ "$MIN_GENERATION" =~ ^[0-9]+$ ]] || die "min-generation '${MIN_GENERATION}' must be a non-negative integer"
  [[ -d "$MESH_TRUST_STORE" ]] \
    || die "trust store ${MESH_TRUST_STORE} is not a directory — no pinned pubkey, no admission"

  # ── RAW source: *_BASE_DIR override > foreign cache > pinned fetch ──────────
  ENV_KEY="$(printf '%s' "$NAME" | tr 'a-z-' 'A-Z_')_BASE_DIR"
  OVERRIDE="${!ENV_KEY:-}"
  RAW=""
  if [[ -n "$OVERRIDE" ]]; then
    [[ -d "$OVERRIDE" ]] || die "${ENV_KEY}='${OVERRIDE}' is not a directory"
    RAW="$(cd "$OVERRIDE" && pwd)"
    log "foreign RAW source for ${REPO}: ${RAW} (via ${ENV_KEY}) — UNTRUSTED until the ingestion gate passes"
  else
    FCLONE_DIR="${REPO_BASE_CACHE}/foreign/${FOREIGN_MESH}/${REPO}"
    command -v git >/dev/null 2>&1 || die "git not found"
    if [[ -d "${FCLONE_DIR}/.git" ]]; then
      if [[ "$OFFLINE" == "1" ]]; then
        log "offline: reusing cached foreign clone ${FCLONE_DIR} (checkout ${PINNED_DIGEST})"
      else
        log "fetching pinned digest ${PINNED_DIGEST} for ${REPO} from mesh '${FOREIGN_MESH}'"
        git -C "$FCLONE_DIR" fetch --depth 1 origin "$PINNED_DIGEST" >&2 2>&1 \
          || log "warning: pinned-digest fetch failed; trying the cached objects"
      fi
      git -C "$FCLONE_DIR" checkout -q --detach "$PINNED_DIGEST" 2>/dev/null \
        || die "cannot check out pinned digest ${PINNED_DIGEST} in ${FCLONE_DIR} (object absent)"
      RAW="$FCLONE_DIR"
    else
      [[ "$OFFLINE" == "1" ]] \
        && die "offline and no foreign base present for ${REPO} (no ${ENV_KEY} override, no cache at ${FCLONE_DIR})"
      [[ -n "$FOREIGN_GIT_BASE" ]] \
        || die "mesh '${FOREIGN_MESH}' registry row has no gitBase and FOREIGN_GIT_BASE is unset"
      log "cloning FOREIGN base ${FOREIGN_GIT_BASE}/${REPO}.git @ ${PINNED_DIGEST} -> ${FCLONE_DIR} (UNTRUSTED until gated)"
      mkdir -p "$FCLONE_DIR"
      git -C "$FCLONE_DIR" init -q
      git -C "$FCLONE_DIR" remote add origin "${FOREIGN_GIT_BASE}/${REPO}.git" 2>/dev/null || true
      # Fetch the immutable digest itself; fall back to a full fetch for forges
      # that refuse sha-in-want. Either way we END on the pinned digest or die.
      git -C "$FCLONE_DIR" fetch --depth 1 origin "$PINNED_DIGEST" >&2 2>&1 \
        || git -C "$FCLONE_DIR" fetch origin >&2 2>&1 \
        || die "cannot fetch ${FOREIGN_GIT_BASE}/${REPO}.git"
      git -C "$FCLONE_DIR" checkout -q --detach "$PINNED_DIGEST" 2>/dev/null \
        || die "pinned digest ${PINNED_DIGEST} not reachable at ${FOREIGN_GIT_BASE}/${REPO}.git"
      RAW="$FCLONE_DIR"
    fi
  fi

  # ── THE GATE — a foreign base is returned ONLY as an ADMITTED snapshot ──────
  QUAR="${REPO_BASE_CACHE}/.mesh-quarantine/${NAME}"
  mkdir -p "$QUAR"
  ADMITTED=""
  if ! ADMITTED="$(bash "${HERE}/ingest-foreign-base.sh" \
        --base "$RAW" --mesh-id "$FOREIGN_MESH" --pinned-digest "$PINNED_DIGEST" \
        --trust-store "$MESH_TRUST_STORE" --quarantine "$QUAR" \
        --min-generation "$MIN_GENERATION")"; then
    die "foreign base for ${REPO} REJECTED by ingest-foreign-base.sh (mesh '${FOREIGN_MESH}') — nothing returned, nothing admitted"
  fi
  [[ -n "$ADMITTED" && -d "$ADMITTED" && -f "${ADMITTED}/.snapdragon-mesh-admitted" ]] \
    || die "ingestion gate returned no admitted snapshot — fail-closed"
  log "foreign base ADMITTED (mesh=${FOREIGN_MESH} pin=${PINNED_DIGEST}): ${ADMITTED}"
  printf '%s\n' "$ADMITTED"
  exit 0
fi

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
# DEFERRED (documented, not a bug): the FIRST-PARTY base is git-cloned over TLS
# with NO commit signature / content-digest / provenance / SBOM / vuln
# verification. That is an ACCEPTABLE deferral ONLY because the base is
# FIRST-PARTY (Snapdragon-Systems, same mesh) pulled over TLS — treat it as
# trusted-transport, not trusted-and-verified. A compromised upstream could
# inject non-secret code (Dockerfile/src) that neither the secret scanner nor
# the drift validator (checks only the overlaid files) would catch. FOREIGN
# mesh-code bases are NOT under this deferral: they go through --foreign mode
# above, which requires the full Phase-7 ingestion gate
# (scripts/ingest-foreign-base.sh). See docs/MESH-TEMPLATING.md, Phase 7.
log "cloning read-only base ${GIT_BASE}/${REPO}.git @ ${GIT_REF} -> ${CLONE_DIR} (TLS only; integrity UNVERIFIED — Phase 8)"
git clone --depth 1 --branch "$GIT_REF" "${GIT_BASE}/${REPO}.git" "$CLONE_DIR" >&2 2>&1 \
  || die "clone failed for ${GIT_BASE}/${REPO}.git (base absent — caller may fall back to skeleton)"
printf '%s\n' "$CLONE_DIR"
exit 0

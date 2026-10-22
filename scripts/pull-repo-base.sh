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
#   GIT_BASE         (default https://github.com/hugmesh)  clone base URL.
#                    Point at the internal mirror on the VPN, e.g.
#                    GIT_BASE=https://gitlab.hugmesh.net/hugmesh
#   GIT_REF          (default main)  branch/tag to check out.
#   --ref TAG|SHA    explicit VERSIONED pin for the own-mesh pull (templating
#                    re-render-at-a-version). Unlike the best-effort GIT_REF env
#                    path, an unresolvable --ref FAILS CLOSED (no silent stale
#                    cache reuse), and a 40-hex sha is fetched directly (clone
#                    --branch cannot take a sha). Refused with --foreign — a
#                    foreign base is pinned by IMMUTABLE digest via the gate.
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

# ── _prb_run_capped MAX_BYTES WATCH_DIR CMD... (R6 byte watchdog) ────────────────
# Run CMD (a git fetch/clone OR checkout) with a background watchdog that polls
# WATCH_DIR's size and KILLs the whole process group the moment it exceeds MAX_BYTES,
# so an unbounded hostile clone OR a decompression-bomb checkout is aborted MID-FLIGHT
# instead of after it has filled the disk. Returns non-zero if CMD failed OR the
# watchdog aborted it. setsid puts CMD in its own process group so the SIGKILL reaches
# git AND its git-remote-* / checkout worker helpers.
_prb_run_capped() {
  local cap="$1" wdir="$2"; shift 2
  local pid wd sz rc=0
  setsid "$@" & pid=$!
  (
    while kill -0 "$pid" 2>/dev/null; do
      sz="$(du -sb "$wdir" 2>/dev/null | awk '{print $1+0}')"
      if [ "${sz:-0}" -gt "$cap" ]; then
        kill -TERM -"$pid" 2>/dev/null; sleep 0.3; kill -KILL -"$pid" 2>/dev/null
        break
      fi
      sleep 0.1
    done
  ) & wd=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill "$wd" 2>/dev/null || true; wait "$wd" 2>/dev/null || true
  sz="$(du -sb "$wdir" 2>/dev/null | awk '{print $1+0}')"
  if [ "${sz:-0}" -gt "$cap" ]; then
    log "byte cap ${cap} exceeded (${sz}) — aborted the foreign clone/fetch/checkout mid-flight (R6)"
    return 1
  fi
  return "$rc"
}

# ── _prb_checkout_capped DIGEST DIR (R6 checkout-time byte watchdog) ─────────────
# git stores blobs COMPRESSED in the pack the fetch downloaded; `git checkout` is the
# step that INFLATES them onto disk. So a decompression-bomb pinned tree — a small pack
# (well under the fetch cap, so the FETCH watchdog never fires) that expands to tens of
# GiB on checkout — would exhaust disk HERE: after the byte-capped fetch, before
# _prb_enforce_source_caps can even measure du. Wrap the checkout in the SAME
# process-group watchdog so it is KILLed MID-CHECKOUT the instant the clone dir crosses
# the cap, not after it has filled the volume. Capped at FOREIGN_MAX_BYTES — the exact
# ceiling _prb_enforce_source_caps enforces post-copy — so a legit tree (comfortably
# under the cap) is never falsely aborted (checkout only ever GROWS the dir), while a
# bomb is stopped as it inflates. '>&2' keeps git's own chatter off our stdout (which
# must carry ONLY the admitted path) while leaving the watchdog's abort log visible.
_prb_checkout_capped() {
  local digest="$1" dir="$2"
  _prb_run_capped "$FOREIGN_MAX_BYTES" "$dir" \
    git -C "$dir" checkout -q --detach "$digest" >&2
}

# ── _prb_enforce_source_caps DIR (R6 post-fetch, pre-gate inode/byte cap) ────────
# A hostile foreign RAW source over the inode/byte cap is refused HERE — ahead of the
# ingestion gate's own pre-copy caps — so the rest of the pipeline never even starts
# on a tree that already blew the bound. HOISTED like the gate's DoS caps.
_prb_enforce_source_caps() {
  local dir="$1" n b
  # `set +o pipefail` INSIDE the substitution subshell, and only here. head MUST
  # keep exiting early — a DoS guard may not enumerate a hostile tree in full —
  # and head exiting is exactly what SIGPIPEs find. Under this file's
  # `set -euo pipefail` that 141 became the pipeline's status and `set -e` killed
  # the script AT THE ASSIGNMENT, so on the one input this guard exists to refuse
  # it aborted with no message instead of running the `die` below. Measured: a
  # 3000-entry tree against a cap of 100 exited 141 and printed nothing.
  # Draining (awk/wc without head) would fix the status and defeat the guard.
  n="$(set +o pipefail; find "$dir" -mindepth 1 2>/dev/null | head -n "$((FOREIGN_MAX_FILES + 1))" | wc -l | tr -d ' ')"
  [ "${n:-0}" -le "$FOREIGN_MAX_FILES" ] \
    || die "foreign source ${dir} has > ${FOREIGN_MAX_FILES} entries (DoS/zip-bomb guard, pre-gate R6)"
  b="$(du -sb "$dir" 2>/dev/null | awk '{print $1+0}')"
  [ -z "$b" ] || [ "$b" -le "$FOREIGN_MAX_BYTES" ] \
    || die "foreign source ${dir} is ${b} bytes > ${FOREIGN_MAX_BYTES} (DoS guard, pre-gate R6)"
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"

# shellcheck source=scripts/_github-auth-lib.sh
. "${HERE}/_github-auth-lib.sh"

# The GitHub org and every repo under it are on the hugmesh names; see
# docs/ORG-MOVE-TODO.md for the remaining non-GitHub sibling flips.
GIT_BASE="${GIT_BASE:-https://github.com/hugmesh}"

# The admission stamp ingest-foreign-base.sh WRITES into a quarantine snapshot.
ADMIT_STAMP=".hugmesh-mesh-admitted"

# _admit_stamp_path DIR -> echoes the admission stamp inside DIR; returns 1 and
# echoes nothing when it does not exist.
_admit_stamp_path() {
  if [[ -f "$1/${ADMIT_STAMP}" ]]; then printf '%s\n' "$1/${ADMIT_STAMP}"
  else return 1; fi
}
GIT_REF="${GIT_REF:-main}"
REPO_BASE_CACHE="${REPO_BASE_CACHE:-${REPO_ROOT}/.repo-base}"
OFFLINE="${OFFLINE:-0}"

# Phase 7 foreign-mesh knobs (flags below override; FOREIGN_MESH env implies --foreign).
FOREIGN=0
FOREIGN_MESH="${FOREIGN_MESH:-}"
[[ -n "$FOREIGN_MESH" ]] && FOREIGN=1
PINNED_DIGEST="${FOREIGN_PINNED_DIGEST:-}"
MIN_GENERATION="${FOREIGN_MIN_GENERATION:-}"
# R3: the operator's signer-INDEPENDENT canonical tree digest of the pinned base. On
# the *_BASE_DIR override path (no git commit->tree binding) this is REQUIRED so the
# gate binds the pin to the ACTUAL bytes, not the signer's self-declared treeSha256.
PINNED_TREE_SHA256="${FOREIGN_PINNED_TREE_SHA256:-}"
MESH_TRUST_STORE="${MESH_TRUST_STORE:-${REPO_ROOT}/keys-template/mesh-trust}"
MESH_REGISTRY="${MESH_REGISTRY:-${REPO_ROOT}/templates/mesh-trust/registry.json}"
# R6: bound a hostile foreign clone BEFORE it exhausts build-host disk. A byte watchdog
# aborts BOTH the fetch (compressed transfer) AND the checkout (which INFLATES the pack
# onto disk — the decompression-bomb step a fetch-only cap misses) mid-flight; a
# post-fetch inode/byte cap then fires ahead of the ingestion gate (mirrors the gate's
# hoisted DoS-cap pattern).
FOREIGN_MAX_BYTES="${FOREIGN_MAX_BYTES:-268435456}"        # 256 MiB (== gate FIB_MAX_BYTES)
FOREIGN_MAX_FILES="${FOREIGN_MAX_FILES:-20000}"            # == gate FIB_MAX_FILES
FOREIGN_FETCH_MAX_BYTES="${FOREIGN_FETCH_MAX_BYTES:-${FOREIGN_MAX_BYTES}}"

NAME=""
PIN_REF=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --foreign)        FOREIGN=1; shift ;;
    --mesh)           FOREIGN=1; FOREIGN_MESH="$2"; shift 2 ;;
    --pinned-digest)  PINNED_DIGEST="$2"; shift 2 ;;
    --pinned-tree-sha256) PINNED_TREE_SHA256="$2"; shift 2 ;;
    --trust-store)    MESH_TRUST_STORE="$2"; shift 2 ;;
    --min-generation) MIN_GENERATION="$2"; shift 2 ;;
    --ref)            PIN_REF="$2"; shift 2 ;;
    -*) die "unknown flag '$1' (usage: $0 [--ref TAG|SHA] [--foreign --mesh ID [--pinned-digest SHA] [--pinned-tree-sha256 SHA] [--trust-store DIR] [--min-generation N]] <repo-short-name>)" ;;
    *)  [[ -z "$NAME" ]] || die "exactly one <repo-short-name> expected (got '${NAME}' and '$1')"
        NAME="$1"; shift ;;
  esac
done
[[ -n "$NAME" ]] || die "usage: $0 [--ref TAG|SHA] [--foreign --mesh ID ...] <repo-short-name>   (e.g. login-ui)"

# ── --ref (versioned own-mesh pin) shape + mode guards ──────────────────────
if [[ -n "$PIN_REF" ]]; then
  [[ "$PIN_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,120}$ && "$PIN_REF" != *..* ]] \
    || die "invalid --ref '${PIN_REF}' (want a tag/branch/sha: [A-Za-z0-9._/-], no '..')"
  [[ "$FOREIGN" -eq 0 ]] \
    || die "--ref cannot be combined with --foreign (a foreign base is pinned by an IMMUTABLE digest through the ingestion gate, never a ref)"
fi
# Slug allowlist: DNS-label-ish short name, so it is safe as a path component and
# as an env-var suffix. (login-ui, admin-bff-api, …)
[[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
  || die "invalid repo short name '${NAME}' (want a DNS label)"

REPO="hugmesh-${NAME}"

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
  # R2/R4: a mesh REVOKED after its base was cached is refused before any fetch/gate.
  [[ "$(jq -r '.revoked // false' <<<"$row")" != "true" ]] \
    || die "mesh '${FOREIGN_MESH}' is REVOKED in ${MESH_REGISTRY} — refusing cached-base reuse (R4 revocation)"
  [[ "$(jq -r '.enabled // false' <<<"$row")" == "true" ]] \
    || die "mesh '${FOREIGN_MESH}' is not enabled in ${MESH_REGISTRY} — refusing"
  # Registry row supplies defaults; explicit --pinned-digest/--min-generation win.
  [[ -n "$PINNED_DIGEST" ]]  || PINNED_DIGEST="$(jq -r '.pinnedDigest // empty' <<<"$row")"
  [[ -n "$MIN_GENERATION" ]] || MIN_GENERATION="$(jq -r '.minGeneration // 0' <<<"$row")"
  FOREIGN_GIT_BASE="${FOREIGN_GIT_BASE:-$(jq -r '.gitBase // empty' <<<"$row")}"
  # R3: operator content anchor (canonical tree digest) — explicit flag/env wins,
  # else the registry's pinnedTreeSha256. Bound to the actual bytes by the gate.
  [[ -n "$PINNED_TREE_SHA256" ]] || PINNED_TREE_SHA256="$(jq -r '.pinnedTreeSha256 // empty' <<<"$row")"
  [[ -z "$PINNED_TREE_SHA256" || "$PINNED_TREE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "pinned-tree-sha256 '${PINNED_TREE_SHA256}' is not a 64-hex canonical tree digest"
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
  # R3: an override / local base has NO git commit->tree binding, so the operator's
  # pin must be re-checked against the ACTUAL bytes via an independent content anchor
  # — else the signer's self-declared treeSha256 is the sole content authority.
  ANCHOR_ARGS=()
  if [[ -n "$OVERRIDE" ]]; then
    [[ -d "$OVERRIDE" ]] || die "${ENV_KEY}='${OVERRIDE}' is not a directory"
    RAW="$(cd "$OVERRIDE" && pwd)"
    [[ -n "$PINNED_TREE_SHA256" ]] \
      || die "override base (${ENV_KEY}) requires an operator content anchor: set --pinned-tree-sha256 / FOREIGN_PINNED_TREE_SHA256 or registry pinnedTreeSha256 (R3 — no git binds the pin to these bytes)"
    ANCHOR_ARGS=(--require-content-anchor --expect-tree-sha256 "$PINNED_TREE_SHA256")
    log "foreign RAW source for ${REPO}: ${RAW} (via ${ENV_KEY}) — UNTRUSTED until the ingestion gate passes (content-anchored to ${PINNED_TREE_SHA256:0:16}…)"
  else
    FCLONE_DIR="${REPO_BASE_CACHE}/foreign/${FOREIGN_MESH}/${REPO}"
    command -v git >/dev/null 2>&1 || die "git not found"
    # A git-anchored base binds the pin to the bytes cryptographically; still pass the
    # operator anchor when present (defense in depth), but it is not required here.
    [[ -n "$PINNED_TREE_SHA256" ]] && ANCHOR_ARGS=(--expect-tree-sha256 "$PINNED_TREE_SHA256")
    if [[ -d "${FCLONE_DIR}/.git" ]]; then
      if [[ "$OFFLINE" == "1" ]]; then
        log "offline: reusing cached foreign clone ${FCLONE_DIR} (checkout ${PINNED_DIGEST})"
      else
        log "fetching pinned digest ${PINNED_DIGEST} for ${REPO} from mesh '${FOREIGN_MESH}' (byte-capped ${FOREIGN_FETCH_MAX_BYTES})"
        _prb_run_capped "$FOREIGN_FETCH_MAX_BYTES" "$FCLONE_DIR" \
          git -C "$FCLONE_DIR" fetch --depth 1 origin "$PINNED_DIGEST" >&2 \
          || log "warning: pinned-digest fetch failed/aborted; trying the cached objects"
      fi
      # R6: the checkout is byte-capped by the SAME watchdog as the fetch — a pinned
      # tree that decompresses to a runaway working tree is aborted MID-CHECKOUT, before
      # it can fill the disk (the fetch cap alone left this inflate step unguarded).
      _prb_checkout_capped "$PINNED_DIGEST" "$FCLONE_DIR" \
        || die "cannot check out pinned digest ${PINNED_DIGEST} in ${FCLONE_DIR} (object absent or byte-cap-aborted mid-checkout, R6)"
      RAW="$FCLONE_DIR"
    else
      [[ "$OFFLINE" == "1" ]] \
        && die "offline and no foreign base present for ${REPO} (no ${ENV_KEY} override, no cache at ${FCLONE_DIR})"
      [[ -n "$FOREIGN_GIT_BASE" ]] \
        || die "mesh '${FOREIGN_MESH}' registry row has no gitBase and FOREIGN_GIT_BASE is unset"
      log "cloning FOREIGN base ${FOREIGN_GIT_BASE}/${REPO}.git @ ${PINNED_DIGEST} -> ${FCLONE_DIR} (UNTRUSTED until gated; byte-capped ${FOREIGN_FETCH_MAX_BYTES})"
      mkdir -p "$FCLONE_DIR"
      git -C "$FCLONE_DIR" init -q
      git -C "$FCLONE_DIR" remote add origin "${FOREIGN_GIT_BASE}/${REPO}.git" 2>/dev/null || true
      # Fetch the immutable digest itself; fall back to a full fetch for forges that
      # refuse sha-in-want. Each fetch is byte-capped by the watchdog so a hostile
      # unbounded clone is aborted MID-TRANSFER (R6), before it can fill the disk.
      _prb_run_capped "$FOREIGN_FETCH_MAX_BYTES" "$FCLONE_DIR" \
          git -C "$FCLONE_DIR" fetch --depth 1 origin "$PINNED_DIGEST" >&2 \
        || _prb_run_capped "$FOREIGN_FETCH_MAX_BYTES" "$FCLONE_DIR" \
          git -C "$FCLONE_DIR" fetch origin >&2 \
        || die "cannot fetch ${FOREIGN_GIT_BASE}/${REPO}.git (failed or byte-cap-aborted)"
      # R6: byte-capped checkout (see the cached branch above) — a decompression-bomb
      # pinned tree is aborted MID-CHECKOUT before it exhausts the build volume.
      _prb_checkout_capped "$PINNED_DIGEST" "$FCLONE_DIR" \
        || die "pinned digest ${PINNED_DIGEST} not reachable at ${FOREIGN_GIT_BASE}/${REPO}.git (object absent or byte-cap-aborted mid-checkout, R6)"
      RAW="$FCLONE_DIR"
    fi
  fi

  # R6: post-fetch, pre-gate inode/byte cap — refuse a hostile RAW source ahead of
  # the ingestion gate so the rest of the pipeline never starts on an over-cap tree.
  _prb_enforce_source_caps "$RAW"

  # ── THE GATE — a foreign base is returned ONLY as an ADMITTED snapshot ──────
  QUAR="${REPO_BASE_CACHE}/.mesh-quarantine/${NAME}"
  mkdir -p "$QUAR"
  ADMITTED=""
  if ! ADMITTED="$(bash "${HERE}/ingest-foreign-base.sh" \
        --base "$RAW" --mesh-id "$FOREIGN_MESH" --pinned-digest "$PINNED_DIGEST" \
        --trust-store "$MESH_TRUST_STORE" --quarantine "$QUAR" \
        --registry "$MESH_REGISTRY" --min-generation "$MIN_GENERATION" \
        "${ANCHOR_ARGS[@]}")"; then
    die "foreign base for ${REPO} REJECTED by ingest-foreign-base.sh (mesh '${FOREIGN_MESH}') — nothing returned, nothing admitted"
  fi
  [[ -n "$ADMITTED" && -d "$ADMITTED" ]] && _admit_stamp_path "$ADMITTED" >/dev/null \
    || die "ingestion gate returned no admitted snapshot — fail-closed"
  log "foreign base ADMITTED (mesh=${FOREIGN_MESH} pin=${PINNED_DIGEST}): ${ADMITTED}"
  printf '%s\n' "$ADMITTED"
  exit 0
fi

# ── _prb_pin_ref CLONE_DIR REF — FAIL-CLOSED checkout of an explicit --ref ──────
# The GIT_REF env path below stays best-effort (warn + reuse cache) for backwards
# compatibility; an EXPLICIT --ref is a versioned-render pin and must never
# silently degrade to a stale/wrong tree. A 40-hex sha is fetched directly
# (clone/fetch --branch cannot take a sha); tags/branches fetch the ref itself and
# detach at FETCH_HEAD (exactly what was fetched — no local-tag/branch mapping
# ambiguity). OFFLINE=1: no fetch, the ref must resolve from cached objects.
_prb_pin_ref() {
  local dir="$1" ref="$2"
  if [[ "$OFFLINE" == "1" ]]; then
    git -C "$dir" checkout -q --detach "$ref" 2>/dev/null \
      || die "offline and pinned --ref '${ref}' does not resolve from the cached objects in ${dir} — fail-closed (no silent fallback)"
    return 0
  fi
  git -C "$dir" fetch --depth 1 origin "$ref" >&2 2>&1 \
    || die "cannot fetch pinned --ref '${ref}' for ${REPO} — fail-closed (no silent fallback to a stale cache)"
  git -C "$dir" checkout -q --detach FETCH_HEAD 2>/dev/null \
    || die "cannot check out pinned --ref '${ref}' (FETCH_HEAD) in ${dir}"
}

# 1) Explicit local read-only base override (this pilot points at the present clone).
ENV_KEY="$(printf '%s' "$NAME" | tr 'a-z-' 'A-Z_')_BASE_DIR"
OVERRIDE="${!ENV_KEY:-}"
if [[ -n "$OVERRIDE" ]]; then
  [[ -d "$OVERRIDE" ]] || die "${ENV_KEY}='${OVERRIDE}' is not a directory"
  abs="$(cd "$OVERRIDE" && pwd)"
  # --ref + override: nothing is fetched, so the pin cannot be applied here. The
  # caller records the ref as the operator's CLAIM (render-repo-tree.sh marker
  # note); provenance base.commitSha stays the ground truth.
  [[ -n "$PIN_REF" ]] && log "NOTE: --ref '${PIN_REF}' with a ${ENV_KEY} override — the local dir is used AS-IS (ref not applied; operator's claim)"
  log "using local read-only base for ${REPO}: ${abs} (via ${ENV_KEY}); NOT fetched, NOT copied into the generator"
  printf '%s\n' "$abs"
  exit 0
fi

# 2) Present cache clone — reuse (fast-forward when online, use as-is when offline).
CLONE_DIR="${REPO_BASE_CACHE}/${REPO}"
if [[ -d "${CLONE_DIR}/.git" ]]; then
  if [[ -n "$PIN_REF" ]]; then
    log "pinning cached base ${CLONE_DIR} to --ref ${PIN_REF} (fail-closed)"
    _prb_pin_ref "$CLONE_DIR" "$PIN_REF"
  elif [[ "$OFFLINE" == "1" ]]; then
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

# 3a) Fresh clone at an explicit --ref pin (fail-closed; sha needs init+fetch).
if [[ -n "$PIN_REF" ]]; then
  log "cloning read-only base ${GIT_BASE}/${REPO}.git @ pinned --ref ${PIN_REF} -> ${CLONE_DIR} (TLS only; integrity UNVERIFIED — Phase 8)"
  if [[ "$PIN_REF" =~ ^[0-9a-f]{40}$ ]]; then
    mkdir -p "$CLONE_DIR"
    git -C "$CLONE_DIR" init -q
    git -C "$CLONE_DIR" remote add origin "${GIT_BASE}/${REPO}.git" 2>/dev/null || true
    _prb_pin_ref "$CLONE_DIR" "$PIN_REF"
  else
    git clone --depth 1 --branch "$PIN_REF" "${GIT_BASE}/${REPO}.git" "$CLONE_DIR" >&2 2>&1 \
      || die "clone at pinned --ref '${PIN_REF}' failed for ${GIT_BASE}/${REPO}.git — fail-closed (an explicit version pin never falls back)"
  fi
  printf '%s\n' "$CLONE_DIR"
  exit 0
fi
# DEFERRED (documented, not a bug): the FIRST-PARTY base is git-cloned over TLS
# with NO commit signature / content-digest / provenance / SBOM / vuln
# verification. That is an ACCEPTABLE deferral ONLY because the base is
# FIRST-PARTY (hugmesh, same mesh) pulled over TLS — treat it as
# trusted-transport, not trusted-and-verified. A compromised upstream could
# inject non-secret code (Dockerfile/src) that neither the secret scanner nor
# the drift validator (checks only the overlaid files) would catch. FOREIGN
# mesh-code bases are NOT under this deferral: they go through --foreign mode
# above, which requires the full Phase-7 ingestion gate
# (scripts/ingest-foreign-base.sh). See docs/MESH-TEMPLATING.md, Phase 7.
log "cloning read-only base ${GIT_BASE}/${REPO}.git @ ${GIT_REF} -> ${CLONE_DIR} (TLS only; integrity UNVERIFIED — Phase 8)"
# ASK FOR CREDENTIALS FIRST. hugmesh is private, so an unauthenticated
# clone here used to die with git's own "could not read Username for
# 'https://github.com'" (no TTY) or block on a Username/Password prompt GitHub
# stopped honouring in 2021 (TTY). gh_auth_ensure resolves a token, offers
# `gh auth login` when a human is actually present, and otherwise fails fast with
# one actionable line. Only github.com needs this — a GIT_BASE pointing at the
# in-cluster GitLab mirror or a local path must not be made to ask for a PAT.
_gh_armed=0
case "${GIT_BASE}" in
  *github.com*)
    if gh_auth_ensure "${GIT_BASE}/${REPO}.git"; then
      _gh_armed=1
    else
      die "GitHub credentials required for ${GIT_BASE}/${REPO}.git — see the [github-auth] lines above"
    fi
    ;;
esac
# NOTE the `if` forms below rather than `[ x = 1 ] && cleanup`: this script runs
# under `set -euo pipefail`, where a bare `test && cmd` statement whose TEST fails
# is itself a failing command and would abort the script on the ordinary
# no-auth-needed path (e.g. a local or GitLab GIT_BASE).
if ! git clone --depth 1 --branch "$GIT_REF" "${GIT_BASE}/${REPO}.git" "$CLONE_DIR" >&2 2>&1; then
  if [ "${_gh_armed}" = 1 ]; then gh_auth_askpass_end; fi
  die "clone failed for ${GIT_BASE}/${REPO}.git (base absent — caller may fall back to skeleton)"
fi
if [ "${_gh_armed}" = 1 ]; then gh_auth_askpass_end; fi
printf '%s\n' "$CLONE_DIR"
exit 0

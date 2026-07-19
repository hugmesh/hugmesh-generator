#!/usr/bin/env bash
# ============================================================================
# render-repo-tree.sh — render_repo_tree() for the mesh repo-templating pilot.
# ============================================================================
#
#  >>> BUILD-HOST ONLY. This invokes `node` (the Phase-1 Handlebars renderer), <<<
#  >>> which MUST NOT run as root on the mesh-node fail-closed root-cron       <<<
#  >>> reconcile path (Phase 6). See docs/MESH-TEMPLATING.md,                  <<<
#  >>> "Node-not-root-on-the-mesh-cron-path".                                  <<<
#
# OPT-IN, ADDITIVE. This is NOT wired into any default path: the DEFAULT sed
# cluster-manifest renderer (generate-brand-repos.sh) is untouched. This produces
# a FULL per-tenant repo tree for a Tier-1-overlaid app repo (pilot: login-ui):
#
#   1. pull the Tier-2 base READ-ONLY (scripts/pull-repo-base.sh) — never copied
#      into the generator tree/commit;
#   2. overlay the ARCHETYPE delta (templates/archetypes/<archetype>) ONTO a private
#      copy of the base in an OUT dir: CLASS-A whole-file .hbs via the Phase-1
#      REAL-Handlebars path (render-handlebars.js) + CLASS-B anchored, presence-
#      tolerant recipe edits (render-recipe.js) on the base's OWN files. The repo's
#      archetype comes from the repos[] manifest (--archetype); per-repo identity
#      is --set tokens. Rendering is NOT reimplemented here;
#   3. gate the emitted tree with the Phase-1 fail-closed secret scanner
#      (scripts/secret-scan.sh) — MUST pass or we refuse to emit;
#   4. FALL BACK to templates/archetypes/<archetype>/_skeleton/ when the base is
#      absent (never refuses; MFE skeleton is bootable, BFF/gateway is a
#      non-buildable placeholder).
#
# Usage:
#   scripts/render-repo-tree.sh brands/example.conf --enable-repo-tree \
#       [--repo login-ui] [--out-dir ./out] [--base DIR] [--ref TAG|SHA] \
#       [--foreign-mesh ID --pinned-digest SHA [--trust-store DIR] [--min-generation N]]
#
# --enable-repo-tree is REQUIRED (the opt-in gate). --base DIR forces a specific
# read-only base (else pull-repo-base.sh resolves it; set <NAME>_BASE_DIR to point
# at a present clone). Exit 0 on a scanned-clean tree; non-zero on any failure.
#
# FOREIGN-MESH MODE (Phase 7): --foreign-mesh ID declares the base comes from a
# FOREIGN mesh (fully hostile until proven). The base is then REQUIRED to pass the
# fail-closed inbound gate (scripts/ingest-foreign-base.sh: digest-pin, pinned-key
# signature, SBOM/vuln floor, secret scan, frozen-constant screen, containment)
# BEFORE any copy — the overlay reads the gate's ADMITTED quarantine snapshot (the
# same frozen bytes that were verified, never the mutable source). A gate REJECT is
# FATAL: no skeleton fallback, BRAND_OUT is never created, nothing reaches the
# publish tail. The foreign attestation envelope + gate markers never ride into
# the emitted tree.
set -euo pipefail

_die() { echo "[render-repo-tree] FATAL: $*" >&2; exit 1; }
_log() { echo "[render-repo-tree] $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLING="${SCRIPT_DIR}/tooling"

[[ $# -ge 1 ]] || _die "usage: $0 <brands/BRAND.conf> --enable-repo-tree --archetype NAME [--repo NAME] [--set K=V]... [--out-dir DIR] [--base DIR]"
BRAND_CONF="$1"; shift

REPO="login-ui"
ARCHETYPE=""
OUT_DIR="./out"
BASE_OVERRIDE=""
ENABLED=0
# Phase 7 foreign-mesh mode knobs (FOREIGN_MESH env is the no-flag equivalent of
# --foreign-mesh; the trust store defaults to the out-of-band staging root).
FOREIGN_MESH="${FOREIGN_MESH:-}"
PINNED_DIGEST=""
# R3: operator content anchor (canonical tree digest) — flag/env, bound by the gate.
PINNED_TREE_SHA256="${FOREIGN_PINNED_TREE_SHA256:-}"
TRUST_STORE="${MESH_TRUST_STORE:-${REPO_ROOT}/keys-template/mesh-trust}"
# R2/R4: per-mesh admission registry re-consulted on THIS consume path (render), so a
# mesh disabled/revoked after admission cannot be re-rendered from a cached base.
MESH_REGISTRY="${MESH_REGISTRY:-${REPO_ROOT}/templates/mesh-trust/registry.json}"
MIN_GENERATION="0"
# Per-repo IDENTITY tokens (Phase 4): repeatable --set NAME=VALUE from the repos[]
# manifest identity row (e.g. APP_SLUG=user, TITLE_WORD=User, PROFILE=be). These
# are added to the render context on top of the brand-derived tokens. Every NAME
# is fail-closed through the classifier (buildContext); a non-allowlisted or
# secret/frozen NAME aborts the render.
declare -a SET_NAMES=()
declare -a SET_VALUES=()
# RESERVED brand scalars: validated/derived tenant-brand identity exported below
# (lines ~162-163) from the signed brand .conf, each behind a shape guard (BRAND/
# ORG/CLUSTER_DOMAIN DNS checks, BRAND_TITLE forbidden-char guard). A --set token
# is PER-REPO identity (APP_SLUG/TITLE_WORD/PROFILE), NOT brand — so a --set whose
# NAME collides with one of these is REFUSED. Otherwise a crafted repos[].identity
# row (e.g. cluster_domain:) would re-export the scalar AFTER its validator ran,
# shadowing the DNS/forbidden-char guard and enabling YAML line-injection into the
# rendered application.yml. The legitimate identity keys never collide with these.
_RESERVED_SCALARS=" BRAND BRAND_TITLE ORG CLUSTER_DOMAIN NPM_SCOPE HOST_NAME GENERATOR_ORG_GROUP REPO_NAME ORG_SLUG HEADSCALE_URL MESH_TAG "
# --ref <tag|sha>: pin the OWN-MESH base pull to a specific tag/branch/sha (plumbed
# to pull-repo-base.sh --ref). The pinned ref is recorded as a one-line
# `.snapdragon-base-ref` marker in BRAND_OUT so the publish tail can stamp
# provenance base.ref + derive the --pr branch name from it. Empty = today's
# behavior (GIT_REF env / `main`), and NO marker is written — the default emitted
# tree stays byte-identical.
BASE_REF=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --enable-repo-tree) ENABLED=1; shift ;;
    --repo)      REPO="$2"; shift 2 ;;
    --archetype) ARCHETYPE="$2"; shift 2 ;;
    --out-dir)   OUT_DIR="$2"; shift 2 ;;
    --base)      BASE_OVERRIDE="$2"; shift 2 ;;
    --ref)       BASE_REF="$2"; shift 2 ;;
    --foreign-mesh)   FOREIGN_MESH="$2"; shift 2 ;;
    --pinned-digest)  PINNED_DIGEST="$2"; shift 2 ;;
    --pinned-tree-sha256) PINNED_TREE_SHA256="$2"; shift 2 ;;
    --trust-store)    TRUST_STORE="$2"; shift 2 ;;
    --registry)       MESH_REGISTRY="$2"; shift 2 ;;
    --min-generation) MIN_GENERATION="$2"; shift 2 ;;
    --set)
      [[ "$2" == *=* ]] || _die "--set expects NAME=VALUE, got '$2'"
      _sn="${2%%=*}"; _sv="${2#*=}"
      [[ "$_sn" =~ ^[A-Z][A-Z0-9_]*$ ]] || _die "--set NAME '$_sn' must be UPPER_SNAKE"
      # Reserved-scalar collision guard: a --set may NOT shadow a validated brand scalar.
      [[ "$_RESERVED_SCALARS" == *" $_sn "* ]] \
        && _die "--set NAME '$_sn' collides with a reserved brand scalar (per-repo identity may not override brand scalars)"
      # Shape guard: no newline/CR/control char may ride in on an identity VALUE.
      # The renderer emits token values with noEscape:true, so a raw newline would
      # splice an attacker-shaped line into the emitted YAML/config regardless of
      # which allowlisted token carries it. Reject C0 controls + DEL.
      case "$_sv" in
        *[$'\001'-$'\037\177']*) _die "--set VALUE for '$_sn' contains a newline/control character (forbidden: YAML/config line-injection guard)" ;;
      esac
      SET_NAMES+=("$_sn"); SET_VALUES+=("$_sv"); shift 2 ;;
    *) _die "unknown argument: $1" ;;
  esac
done

if [[ "$ENABLED" -ne 1 ]]; then
  echo "[render-repo-tree] OPT-IN GATE: pass --enable-repo-tree to run (build-host only)." >&2
  echo "                   This path is additive and NOT part of any default render." >&2
  exit 2
fi

[[ -f "$BRAND_CONF" ]] || _die "brand config not found: $BRAND_CONF"
[[ "$REPO" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || _die "invalid --repo '$REPO'"

# ── --ref shape validation (versioned own-mesh pull) ─────────────────────────
# A git tag/branch/sha shape: no whitespace/metachars, no '..' (refname rule +
# our tree-escape hygiene), bounded length. FOREIGN bases never take a ref —
# they are pinned by IMMUTABLE digest through the Phase-7 gate.
if [[ -n "$BASE_REF" ]]; then
  [[ "$BASE_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,120}$ && "$BASE_REF" != *..* ]] \
    || _die "invalid --ref '${BASE_REF}' (want a tag/branch/sha: [A-Za-z0-9._/-], no '..')"
  [[ -z "$FOREIGN_MESH" ]] \
    || _die "--ref cannot be combined with --foreign-mesh (a foreign base is pinned by an IMMUTABLE --pinned-digest, never a ref)"
fi

# ── Foreign-mesh mode arg validation (Phase 7, fail-closed) ──────────────────
# Shape checks only — the REAL enforcement (digest pin, pinned-key signature,
# SBOM/vuln/secret/frozen/containment) is ingest-foreign-base.sh below, which
# re-validates everything itself. A declared-foreign render with a missing pin or
# trust store dies HERE, before any base bytes are touched.
if [[ -n "$FOREIGN_MESH" ]]; then
  [[ "$FOREIGN_MESH" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
    || _die "invalid --foreign-mesh '${FOREIGN_MESH}' (must be a DNS label)"
  [[ -n "$PINNED_DIGEST" ]] \
    || _die "--foreign-mesh requires --pinned-digest (an IMMUTABLE commit SHA; a foreign base is never taken from a moving ref)"
  [[ -d "$TRUST_STORE" ]] \
    || _die "foreign-mesh trust store '${TRUST_STORE}' is not a directory (no trust store => no admission; stage pubkeys out-of-band)"
  [[ "$MIN_GENERATION" =~ ^[0-9]+$ ]] \
    || _die "--min-generation must be a non-negative integer"
  # R2/R4: the render base is supplied as a LOCAL dir (--base / resolved), which has
  # no git commit->tree binding — so it is a content-anchored consume path exactly
  # like a *_BASE_DIR override. Resolve the operator anchor (flag/env, else the
  # registry's pinnedTreeSha256) and REQUIRE it; the gate binds it to the bytes (R3).
  command -v jq >/dev/null 2>&1 || _die "jq not found (mesh registry parse) — fail-closed"
  [[ -f "$MESH_REGISTRY" ]] \
    || _die "mesh registry '${MESH_REGISTRY}' absent — no admission policy, fail-closed"
  if [[ -z "$PINNED_TREE_SHA256" ]]; then
    PINNED_TREE_SHA256="$(jq -r --arg m "$FOREIGN_MESH" '.meshes[$m].pinnedTreeSha256 // empty' "$MESH_REGISTRY" 2>/dev/null)"
  fi
  [[ -n "$PINNED_TREE_SHA256" ]] \
    || _die "--foreign-mesh requires an operator content anchor: --pinned-tree-sha256 / FOREIGN_PINNED_TREE_SHA256 or registry pinnedTreeSha256 (R3 — binds the pin to the ACTUAL base bytes, not the signer's self-declared treeSha256)"
  [[ "$PINNED_TREE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || _die "--pinned-tree-sha256 '${PINNED_TREE_SHA256}' is not a 64-hex canonical tree digest"
fi

# ── Resolve the ARCHETYPE overlay dir (Phase 4 generalization) ───────────────
# Phase 2/3 hardcoded OVERLAY_DIR=templates/repos/<repo> (one hand overlay per
# repo). Phase 4: the overlay dir is templates/archetypes/<archetype>, and the
# repo->archetype map lives in the repos[] manifest (passed here via --archetype).
# One archetype overlay serves the whole class; per-repo variance is --set identity.
[[ -n "$ARCHETYPE" ]] || _die "missing --archetype (spring-bff|angular-mfe|gateway|generator) — the repo's class from the repos[] manifest"
[[ "$ARCHETYPE" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || _die "invalid --archetype '$ARCHETYPE'"
OVERLAY_DIR="${REPO_ROOT}/templates/archetypes/${ARCHETYPE}"
[[ -d "$OVERLAY_DIR" ]] || _die "no archetype overlay '${ARCHETYPE}' at ${OVERLAY_DIR}"
RECIPE="${OVERLAY_DIR}/recipe.yaml"

command -v node >/dev/null 2>&1 || _die "node not found (build-host tool)"
[[ -d "${TOOLING}/node_modules/handlebars" ]] \
  || _die "handlebars not installed — run: (cd ${TOOLING} && npm install)"

# ── Load + validate the brand profile (mirrors generate-brand-repos.sh) ──────
# shellcheck source=/dev/null
source "$BRAND_CONF"
: "${BRAND:?brand config must set BRAND}"
: "${BRAND_TITLE:?brand config must set BRAND_TITLE}"
: "${ORG:?brand config must set ORG}"

_DNS_LABEL='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
[[ "$BRAND" =~ $_DNS_LABEL ]] \
  || _die "invalid BRAND '${BRAND}' (must be a DNS label)"
[[ "$ORG" =~ ^[A-Za-z0-9._-]{1,63}$ ]] \
  || _die "invalid ORG '${ORG}' (allowed: A-Za-z0-9._- , 1..63)"
[ -n "$BRAND_TITLE" ] || _die "BRAND_TITLE must not be empty"
case "$BRAND_TITLE" in
  *['"\$`|&']* ) _die "invalid BRAND_TITLE (forbidden chars: \" \\ \$ \` | &)" ;;
esac
[[ "${#BRAND_TITLE}" -le 128 ]] || _die "BRAND_TITLE too long (max 128)"

# CLUSTER_DOMAIN feeds AUTH-relevant env-DEFAULTs in the admin-bff-api overlay
# (application.yml issuer-uri / jwk-set-uri / admin-emails / builder registry).
# Because the renderer uses noEscape:true, an un-validated CLUSTER_DOMAIN carrying
# a newline/whitespace/YAML metacharacter could splice attacker-shaped lines into
# the emitted YAML (e.g. a bogus `leaked-default:` key next to the JWT issuer).
# Validate it as a DNS hostname BEFORE export — parity with the BRAND/ORG/
# BRAND_TITLE guards above. Empty is allowed (the login-ui pilot does not consume
# it); HEADSCALE_URL/MESH_TAG are NOT hostname-shaped and are not overlay tokens
# here, so they are intentionally not hostname-checked.
_HOSTNAME='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'
if [[ -n "${CLUSTER_DOMAIN:-}" ]]; then
  [[ "${#CLUSTER_DOMAIN}" -le 253 ]] \
    || _die "CLUSTER_DOMAIN too long (max 253)"
  [[ "$CLUSTER_DOMAIN" =~ $_HOSTNAME ]] \
    || _die "invalid CLUSTER_DOMAIN '${CLUSTER_DOMAIN}' (must be a DNS hostname; no whitespace/newlines/YAML metacharacters)"
fi

# ── Derive the tenant token values ───────────────────────────────────────────
# NPM_SCOPE: lowercase slug of ORG — SAME slug rule generate-brand-repos.sh uses
# for HARBOR_PROJECT/GITLAB_GROUP (single source of the rule). npm scopes must be
# lowercase; this guarantees a valid @scope.
NPM_SCOPE="${ORG,,}"; NPM_SCOPE="${NPM_SCOPE//[^a-z0-9-]/-}"
NPM_SCOPE="$(echo "$NPM_SCOPE" | sed 's/^-*//; s/-*$//')"
[[ -n "$NPM_SCOPE" ]] || _die "ORG '${ORG}' slugged to an empty npm scope"
# HOST_NAME: the federation host name for this tenant.
HOST_NAME="${BRAND}-host"
# GENERATOR_ORG_GROUP: the CI include project — the tenant's own GitLab group
# hosting the (upstream-named) generator. 'snapdragon-generator' is upstream code
# identity and stays literal; only the org/group is rebranded.
GENERATOR_ORG_GROUP="${NPM_SCOPE}/snapdragon-generator"
# ORG_SLUG: the SAME ORG slug exposed as a PATH-SAFE FILENAME token (the generator
# archetype's renames[] demo emits docs/BRANDING-<ORG_SLUG>.md). Single slug rule:
# identical to NPM_SCOPE by construction — a second derivation would fork the rule.
ORG_SLUG="${NPM_SCOPE}"

# REPO_NAME: the repo short name as a render token (skeleton READMEs reference it).
REPO_NAME="$REPO"
export BRAND BRAND_TITLE ORG NPM_SCOPE HOST_NAME GENERATOR_ORG_GROUP REPO_NAME ORG_SLUG
export CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-}" HEADSCALE_URL="${HEADSCALE_URL:-}" MESH_TAG="${MESH_TAG:-}"
EXTRA_TOKENS="NPM_SCOPE,HOST_NAME,GENERATOR_ORG_GROUP,REPO_NAME,ORG_SLUG"

# Fold in the per-repo IDENTITY --set tokens. Each is exported and appended to
# EXTRA_TOKENS; the classifier (in render-handlebars/render-recipe buildContext)
# fail-closes a non-allowlisted or secret/frozen NAME. Value-side secret/frozen
# screening is the driver's job (render-tenant-set); the emit secret-scan is the
# backstop for a secret VALUE landing in a file.
for _i in "${!SET_NAMES[@]}"; do
  _n="${SET_NAMES[$_i]}"; _v="${SET_VALUES[$_i]}"
  export "${_n}=${_v}"
  EXTRA_TOKENS="${EXTRA_TOKENS},${_n}"
  _log "identity: ${_n}=${_v}"
done

_log "repo=${REPO} archetype=${ARCHETYPE} brand=${BRAND} title='${BRAND_TITLE}' npm-scope=@${NPM_SCOPE} host=${HOST_NAME} gen-group=${GENERATOR_ORG_GROUP}"

# ── Resolve the READ-ONLY base ───────────────────────────────────────────────
BASE=""
if [[ -n "$BASE_OVERRIDE" ]]; then
  [[ -d "$BASE_OVERRIDE" ]] || _die "--base '${BASE_OVERRIDE}' is not a directory"
  BASE="$(cd "$BASE_OVERRIDE" && pwd)"
  _log "using --base ${BASE} (read-only)"
else
  # pull-repo-base.sh prints ONLY the resolved path on stdout (logs -> stderr).
  # An explicit --ref rides through as the puller's --ref (fail-closed there: an
  # unresolvable pinned ref refuses instead of silently falling back to HEAD).
  _ref_args=()
  [[ -n "$BASE_REF" ]] && _ref_args=(--ref "$BASE_REF")
  if BASE="$("${SCRIPT_DIR}/pull-repo-base.sh" ${_ref_args[@]+"${_ref_args[@]}"} "$REPO")"; then
    _log "resolved read-only base: ${BASE}${BASE_REF:+ (pinned ref ${BASE_REF})}"
  else
    BASE=""
    _log "base not pullable — will use skeleton fallback"
  fi
fi

MODE="skeleton"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── Phase 7 FOREIGN-MESH inbound gate (fail-closed, BEFORE any copy) ─────────
# A base declared foreign is REQUIRED to pass scripts/ingest-foreign-base.sh:
# quarantine-snapshot (TOCTOU close) -> containment -> digest-pin -> pinned-key
# signature (no TOFU) -> SBOM -> offline vuln floor -> whole-tree secret scan ->
# frozen-constant screen -> atomic promote. On ADMIT, the overlay reads the gate's
# quarantine SNAPSHOT (the exact verified bytes), never the mutable source dir.
# On REJECT this _die's: NO skeleton fallback (that would mask the rejection and
# still emit a tree), BRAND_OUT is never created (nothing for the publish tail to
# sign/push onward). The quarantine lives under TMP, purged by the EXIT trap.
if [[ -n "$FOREIGN_MESH" ]]; then
  [[ -n "$BASE" && -d "$BASE" ]] \
    || _die "foreign-mesh mode requires a resolvable base (no skeleton fallback for a declared-foreign ingest)"
  _log "FOREIGN base declared (mesh=${FOREIGN_MESH}, pin=${PINNED_DIGEST}) — running inbound ingestion gate"
  ADMITTED=""
  if ! ADMITTED="$(bash "${SCRIPT_DIR}/ingest-foreign-base.sh" \
        --base "$BASE" --mesh-id "$FOREIGN_MESH" --pinned-digest "$PINNED_DIGEST" \
        --trust-store "$TRUST_STORE" --quarantine "${TMP}/foreign-quarantine" \
        --registry "$MESH_REGISTRY" --min-generation "$MIN_GENERATION" \
        --require-content-anchor --expect-tree-sha256 "$PINNED_TREE_SHA256")"; then
    _die "foreign base REJECTED by ingest-foreign-base.sh (mesh=${FOREIGN_MESH}) — refusing to render, nothing emitted"
  fi
  [[ -n "$ADMITTED" && -d "$ADMITTED" && -f "${ADMITTED}/.snapdragon-mesh-admitted" ]] \
    || _die "ingestion gate returned no admitted snapshot — fail-closed"
  BASE="$ADMITTED"
  _log "foreign base ADMITTED: overlaying the verified quarantine snapshot ${BASE}"
fi

# ── OUT dir + realpath containment (mirrors generate-brand-repos.sh) ─────────
# Deliberately AFTER the foreign gate: a rejected foreign base must leave no
# BRAND_OUT behind (the publish tail keys off that tree existing).
BRAND_OUT="${OUT_DIR}/${BRAND}-${REPO}"
_out_abs="$(mkdir -p "$OUT_DIR" 2>/dev/null; realpath -m -- "$OUT_DIR")"
_brand_out_abs="$(realpath -m -- "$BRAND_OUT")"
case "$_brand_out_abs/" in
  "$_out_abs"/*) : ;;
  *) _die "refusing to operate outside OUT_DIR: '${BRAND_OUT}' -> '${_brand_out_abs}'" ;;
esac
[[ -d "$BRAND_OUT" ]] && { _log "removing existing output: $BRAND_OUT"; rm -rf "$BRAND_OUT"; }
mkdir -p "$BRAND_OUT"

if [[ -n "$BASE" && -d "$BASE" ]]; then
  MODE="overlay"
  # 1) Private copy of the READ-ONLY base into OUT (exclude VCS metadata + any
  #    stray build dirs). The base itself is never modified; nothing is copied
  #    INTO the generator tree — OUT is a gitignored staging dir.
  # Exclude VCS + build outputs for BOTH archetypes (JS: node_modules/dist/.angular;
  # compiled Java/Maven BFF: target/). Generalized, not forked per repo — extra
  # excludes are harmless when a repo lacks that dir.
  #    Phase 7: the FOREIGN attestation envelope + gate markers (root-level) are
  #    stripped — they attest the INBOUND base, not OUR outbound tree (the publish
  #    tail writes/signs a FRESH provenance for what WE emit), and the markers are
  #    quarantine bookkeeping. Root-anchored: a same-named file in a SUBDIR is not
  #    an envelope and stays digest-covered/screened by the gate instead. ANY
  #    pre-existing '.snapdragon-base-origin*' is ALSO stripped here (like the
  #    envelope) so an attacker-planted base-origin marker in the foreign base can
  #    never survive — OURS is written authoritatively AFTER the copy (below).
  _log "copying read-only base into ${BRAND_OUT} (excluding .git/node_modules/dist/.angular/target + attestation envelope/markers + any planted base-origin marker)"
  tar -C "$BASE" \
      --exclude='./.git' --exclude='./node_modules' --exclude='./dist' \
      --exclude='./.angular' --exclude='./target' \
      --exclude='./.snapdragon-provenance.json' \
      --exclude='./.snapdragon-provenance.json.sig' \
      --exclude='./.snapdragon-sbom.json' \
      --exclude='./.snapdragon-mesh-admitted' \
      --exclude='./.foreign-mesh-id' \
      --exclude='./.snapdragon-base-ref' \
      --exclude='./.snapdragon-base-origin*' -cf - . | tar -C "$BRAND_OUT" -xf -

  # ── VERSIONED-RENDER MARKER (explicit --ref only) ───────────────────────────
  # One line, the pinned ref. TRAVELS WITH BRAND_OUT (same durable-marker idiom as
  # .snapdragon-base-origin.json) so the publish tail can stamp provenance
  # base.ref and derive the --pr branch `templating/update-<ref>` without being
  # separately told. A stale/planted marker in the BASE is stripped by the tar
  # exclude above; OURS is written after, authoritatively. No --ref => no marker
  # => the default emitted tree stays byte-identical to pre-versioning renders.
  # HONESTY: on a --base/*_BASE_DIR override nothing was fetched, so the marker
  # records the OPERATOR'S CLAIM of the base's version; the fetch-proven half is
  # the pull-repo-base.sh --ref path (which dies on an unresolvable ref). Ground
  # truth either way stays provenance base.commitSha.
  if [[ -n "$BASE_REF" ]]; then
    printf '%s\n' "$BASE_REF" > "${BRAND_OUT}/.snapdragon-base-ref"
    if [[ -n "$BASE_OVERRIDE" ]]; then
      _log "wrote base-ref marker ${BASE_REF} (NOTE: --base override — the ref is the operator's claim, not fetch-proven)"
    else
      _log "wrote base-ref marker ${BASE_REF}"
    fi
  fi

  # ── Phase 7 DURABLE BASE-ORIGIN MARKER (foreign-mesh mode ONLY) ───────────────
  # The publish launder-belt's foreign-origin detection keyed SOLELY off the
  # REMOVABLE foreign cache dir (${REPO_BASE_CACHE}/foreign/<mesh>/snapdragon-<repo>).
  # A purge of that dir after render but before publish left publish blind: it
  # treated this foreign-DERIVED tree as own-mesh/skeleton and re-signed+pushed it
  # with NO admission-stamp re-verify. So for a foreign base we write OUR OWN
  # authoritative, minimal base-origin provenance INTO the emitted tree — it TRAVELS
  # WITH BRAND_OUT and survives a cache purge, giving publish a fail-closed key
  # (marker present => a re-verified '.snapdragon-mesh-admitted' stamp is REQUIRED).
  # This is OUR OUTBOUND lineage (consistent with base.originMesh the publish tail
  # records in the signed provenance), NOT the foreign mesh's INBOUND attestation
  # envelope (which stays STRIPPED above). It is written AFTER the strip on OUR
  # authority, so a planted marker only ever makes publish MORE strict, never less.
  # Own-mesh (non-foreign) render writes NO such marker — BRAND_OUT stays byte-
  # identical to pre-Phase-7 for the skeleton/own-mesh paths.
  if [[ -n "$FOREIGN_MESH" ]]; then
    # The admitted snapshot's canonical tree digest — read from the gate's OWN stamp
    # (BASE is the admitted quarantine snapshot; the stamp is excluded from the copy
    # above but still present in BASE). This is the same digest publish re-verifies
    # against the durable admission stamp. The marker is deliberately MINIMAL and
    # entropy-safe: originMesh (DNS label) + pinnedDigest + treeSha256 (bare 40/64-hex
    # runs sit ~4.0 bits/char, under the secret-scan high-entropy floor). We do NOT
    # embed a stamp path (a mesh-<digest16> path token mixes letters+hex and can, for
    # some digests, cross the 4.5-bit high-entropy floor -> emit-scan false positive);
    # publish reconstructs the stamp location from originMesh itself.
    _admit_tree="$(sed -n 's/^tree-sha256=//p' "${BASE}/.snapdragon-mesh-admitted" 2>/dev/null | head -n1)"
    [[ "$_admit_tree" =~ ^[0-9a-f]{64}$ ]] \
      || _die "admitted snapshot stamp carries no valid tree-sha256 — cannot write base-origin marker (fail-closed)"
    cat > "${BRAND_OUT}/.snapdragon-base-origin.json" <<JSON
{
  "schema": "snapdragon.systems/base-origin/v1",
  "originMesh": "${FOREIGN_MESH}",
  "pinnedDigest": "${PINNED_DIGEST}",
  "treeSha256": "${_admit_tree}"
}
JSON
    _log "wrote durable base-origin marker .snapdragon-base-origin.json (mesh=${FOREIGN_MESH} pin=${PINNED_DIGEST} tree=${_admit_tree})"
  fi

  # 2) CLASS-A overlay: stage the archetype's whole-file .hbs (angular-mfe:
  #    federation-base.js — byte-identical across the class bar HOST_NAME;
  #    gateway: the deploy/*.hbs env overlay). NEVER _skeleton/_identity.env/
  #    README/recipe.yaml. spring-bff has zero class-A files (recipe-only) — the
  #    stage is simply empty and nothing is overlaid. Class-B (repo-owned files
  #    that embed identity) is handled by the recipe engine in step 4.
  STAGE="${TMP}/overlay"; mkdir -p "$STAGE"
  while IFS= read -r -d '' t; do
    rel="${t#"${OVERLAY_DIR}/"}"
    mkdir -p "${STAGE}/$(dirname "$rel")"
    cp "$t" "${STAGE}/${rel}"
  done < <(find "$OVERLAY_DIR" -name '*.hbs' -not -path '*/_skeleton/*' -print0)

  # 3) Render the overlay via the Phase-1 Handlebars path, then lay it onto OUT.
  RENDERED="${TMP}/rendered"; mkdir -p "$RENDERED"
  node "${TOOLING}/render-handlebars.js" \
      --templates "$STAGE" --out "$RENDERED" --extra-tokens "$EXTRA_TOKENS"
  ( cd "$RENDERED" && tar -cf - . ) | ( cd "$BRAND_OUT" && tar -xf - )
  _log "overlaid $(find "$RENDERED" -type f | wc -l | tr -d ' ') brand-coupled file(s) onto the base"

  # BACKSTOP (keyed to "is-an-overlay-rendered-file", not to a path glob): the
  # broad emit scan below is scoped with path excludes (src/main/java, src/test)
  # that are sound for TODAY's overlay (it only renders into src/main/resources +
  # .gitlab-ci.yml). But those excludes are keyed to file PATH — a FUTURE overlay
  # that ever renders a template whose destination lands under an excluded path
  # (e.g. a generated @Value default under src/main/java/**) would fall outside the
  # broad backstop. So ALSO scan the set of files THIS overlay actually rendered,
  # with NO excludes — every overlay-emitted file is guaranteed-scanned regardless
  # of where it lands. Redundant with the broad scan for today's paths (zero new
  # failures possible), fail-closed for tomorrow's.
  _log "scanning the ${RENDERED##*/} overlay-rendered file(s) (no excludes — overlay-output backstop)"
  if ! "${SCRIPT_DIR}/secret-scan.sh" "$RENDERED" >&2; then
    _die "secret scanner flagged an overlay-RENDERED file — refusing to emit ${BRAND_OUT}"
  fi

  # 4) CLASS-B: apply the archetype RECIPE (anchored, presence-tolerant edits) onto
  #    each repo's OWN base file in OUT. This is what generalizes 2 exemplars to N
  #    repos: no whole-file swap of application.yml / package.json / index.html /
  #    .gitlab-ci.yml (those embed the repo's OWN identity), only the brand-coupled
  #    substrings are rewritten. An anchor absent in this repo's base no-ops.
  if [[ -f "$RECIPE" ]]; then
    _log "applying archetype recipe ${RECIPE##*/} (anchored edits) onto ${BRAND_OUT}"
    node "${TOOLING}/render-recipe.js" \
        --recipe "$RECIPE" --target "$BRAND_OUT" \
        --extra-tokens "$EXTRA_TOKENS" \
        --report "${TMP}/recipe-report.json"
    # Backstop: scan exactly the recipe-touched files (no excludes) so a branded
    # substring can never smuggle a secret past the path-scoped emit scan below.
    # renames[] (applied AFTER edits) may have MOVED a touched file, so follow the
    # report's rename map (from -> to) and also scan every rename DESTINATION —
    # a moved file is recipe-touched by definition.
    _touched=()
    while IFS= read -r rel; do
      [[ -n "$rel" && -f "${BRAND_OUT}/${rel}" ]] && _touched+=("${BRAND_OUT}/${rel}")
    done < <(node -e '
      const r = require(process.argv[1]);
      const moved = new Map((r.renames || []).filter(x => x.applied).map(x => [x.from, x.to]));
      for (const f of r.files) {
        if (f.present && (f.anchors || []).some(a => a.hits > 0)) console.log(moved.get(f.file) || f.file);
      }
      for (const to of moved.values()) console.log(to);
    ' "${TMP}/recipe-report.json" | sort -u)
    if [[ ${#_touched[@]} -gt 0 ]]; then
      _log "scanning ${#_touched[@]} recipe-touched file(s) (no excludes — recipe-output backstop)"
      if ! "${SCRIPT_DIR}/secret-scan.sh" "${_touched[@]}" >&2; then
        _die "secret scanner flagged a recipe-TOUCHED file — refusing to emit ${BRAND_OUT}"
      fi
    fi
  fi
else
  # Skeleton fallback: render the whole minimal tree from _skeleton/*.hbs.
  SKEL="${OVERLAY_DIR}/_skeleton"
  [[ -d "$SKEL" ]] || _die "base absent AND no skeleton at ${SKEL}"
  _log "rendering skeleton fallback from ${SKEL}"
  node "${TOOLING}/render-handlebars.js" \
      --templates "$SKEL" --out "$BRAND_OUT" --extra-tokens "$EXTRA_TOKENS"
fi

# ── Phase-1 emit-time secret scanner (fail-closed) ──────────────────────────
# SCOPE: the scan guards the TEMPLATING delta — that no rendered/config/manifest
# file carries a LITERAL secret (every secret field must stay ${ENV}/ESO). It is
# NOT a SAST re-audit of the read-only base's own compiled sources: a compiled
# archetype (e.g. the Spring BFF) ships upstream unit-test crypto FIXTURES + source
# javadoc that name PEM headers / high-entropy sample tokens — legitimate FPs that
# are the BASE repo's own CI concern (the base is trusted-transport here; content
# re-verification is the Phase-8 deferral in pull-repo-base.sh). A brand token
# never lands in *.java, so the compiled-source + test trees are excluded while the
# ENTIRE config/resource/manifest/CI surface (application.yml, .gitlab-ci.yml,
# Dockerfile, settings.xml, deploy/**, …) — where a templated secret WOULD appear —
# is still scanned. The excludes are no-ops for a base without those trees (the
# login-ui pilot), so its emit is unchanged.
_log "running emit-time secret scanner over ${BRAND_OUT} (fail-closed gate; base compiled-source/test trees out of scope)"
if ! "${SCRIPT_DIR}/secret-scan.sh" \
      --exclude '*/src/test/*' \
      --exclude '*/src/main/java/*' \
      "$BRAND_OUT" >&2; then
  _die "secret scanner flagged the emitted tree — refusing to emit ${BRAND_OUT}"
fi

n_files="$(find "$BRAND_OUT" -type f | wc -l | tr -d ' ')"
echo "[render-repo-tree] OK mode=${MODE} files=${n_files} tree=${BRAND_OUT}" >&2
# Machine-readable result on stdout: MODE<TAB>OUT
printf '%s\t%s\n' "$MODE" "$BRAND_OUT"

#!/usr/bin/env bash
# ============================================================================
# provenance.sh — signed per-tenant provenance manifest (Phase 5).
# ============================================================================
#
#  >>> BUILD-HOST ONLY (invoked by scripts/publish-tenant-set.sh). Emits a       <<<
#  >>> `.snapdragon-provenance.json` + detached `.snapdragon-provenance.json.sig`<<<
#  >>> at the root of each rendered tenant repo, capturing WHAT was rendered     <<<
#  >>> (base commit, archetype recipe, generator identity) so the pushed tree    <<<
#  >>> is attributable. Signature = Ed25519 (same family as the baked            <<<
#  >>> registry-pub.ed25519 domain-export verifier), verifiable with the public  <<<
#  >>> key. The manifest+sig carry NO secrets (a public commit SHA + a detached  <<<
#  >>> signature only) and are part of the tree secret-scan.sh gates before push.<<<
#
# DETERMINISM (idempotency contract): the manifest is a PURE FUNCTION of its
# inputs — no wall-clock "now". `producedAt` is the base commit's committer date
# (deterministic per base) or SOURCE_DATE_EPOCH when the base is absent (skeleton
# mode). Ed25519 signatures are deterministic (RFC 8032), so a re-run with the
# same inputs + key yields byte-identical manifest AND signature -> the publish
# tail's second run is a clean no-op (no spurious commit).
#
# Subcommands:
#   provenance.sh write  --repo-dir DIR --brand B --org O --cluster-domain D \
#                        --repo R --archetype A --base-sha SHA --base-mode MODE \
#                        --recipe-sha RSHA --generator-repo GR --generator-commit GC \
#                        [--engine handlebars] [--produced-at ISO8601] \
#                        [--origin-mesh MESH_ID]   # Phase 7: cross-mesh base lineage
#                        (--origin-mesh empty/absent = own mesh = base.originMesh is
#                         OMITTED — every pre-Phase-7 manifest re-renders byte-identical,
#                         preserving the determinism/idempotency contract.)
#                        [--base-ref TAG|SHA]      # versioned-render stamp: the ref the
#                        (own-mesh base was pulled at (render-repo-tree.sh --ref). Emitted
#                         as base.ref; empty/absent = OMITTED — same byte-identical
#                         backwards-compat contract as --origin-mesh. base.commitSha
#                         stays the ground truth; the ref is the human version label
#                         the --pr branch name embeds.)
#   provenance.sh sign   --repo-dir DIR --key ED25519_PRIV.pem
#   provenance.sh verify --repo-dir DIR --pub ED25519_PUB.pem
#   provenance.sh keygen --key PRIV.pem --pub PUB.pem     # TEST keypair (build-host verify)
#
# The MANIFEST NAME is fixed so the appset/consumers can find it deterministically.
set -euo pipefail

MANIFEST=".snapdragon-provenance.json"
SIG=".snapdragon-provenance.json.sig"

_die() { echo "[provenance] FATAL: $*" >&2; exit 1; }
_log() { echo "[provenance] $*" >&2; }

command -v openssl >/dev/null 2>&1 || _die "openssl not found (build-host tool)"

cmd="${1:-}"; shift || true

# ── shared arg parse ────────────────────────────────────────────────────────
REPO_DIR="" BRAND="" ORG="" CLUSTER_DOMAIN="" REPO="" ARCHETYPE=""
BASE_SHA="" BASE_MODE="" RECIPE_SHA="" GEN_REPO="hugmesh-generator" GEN_COMMIT=""
ENGINE="handlebars" PRODUCED_AT="" KEY="" PUB="" ORIGIN_MESH="" BASE_REF=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    --brand) BRAND="$2"; shift 2 ;;
    --org) ORG="$2"; shift 2 ;;
    --cluster-domain) CLUSTER_DOMAIN="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --archetype) ARCHETYPE="$2"; shift 2 ;;
    --base-sha) BASE_SHA="$2"; shift 2 ;;
    --base-mode) BASE_MODE="$2"; shift 2 ;;
    --recipe-sha) RECIPE_SHA="$2"; shift 2 ;;
    --generator-repo) GEN_REPO="$2"; shift 2 ;;
    --generator-commit) GEN_COMMIT="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --produced-at) PRODUCED_AT="$2"; shift 2 ;;
    # Phase 7: the base's ORIGIN mesh id (cross-mesh lineage). OPTIONAL and
    # backwards-compatible — empty = own mesh = base.originMesh is OMITTED, so
    # every pre-Phase-7 manifest re-renders byte-identical (determinism contract).
    --origin-mesh) ORIGIN_MESH="$2"; shift 2 ;;
    # Versioned render (I5): the tag/sha the own-mesh base was pulled at. OPTIONAL
    # and backwards-compatible — empty = base.ref OMITTED (byte-identical manifests).
    --base-ref) BASE_REF="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --pub) PUB="$2"; shift 2 ;;
    *) _die "unknown argument: $1" ;;
  esac
done

# JSON string escaper (control chars, quote, backslash) — the identity fields are
# already shape-validated upstream, but escape at the sink so a manifest is always
# well-formed JSON regardless of caller.
_jesc() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

case "$cmd" in
  keygen)
    [[ -n "$KEY" && -n "$PUB" ]] || _die "keygen needs --key PRIV.pem --pub PUB.pem"
    openssl genpkey -algorithm ed25519 -out "$KEY" >/dev/null 2>&1 || _die "ed25519 keygen failed"
    openssl pkey -in "$KEY" -pubout -out "$PUB" >/dev/null 2>&1 || _die "pubkey extract failed"
    chmod 600 "$KEY" 2>/dev/null || true
    _log "generated TEST ed25519 keypair: priv=${KEY} pub=${PUB}"
    ;;

  write)
    [[ -d "$REPO_DIR" ]] || _die "write needs an existing --repo-dir"
    [[ -n "$BRAND" && -n "$ORG" && -n "$REPO" && -n "$ARCHETYPE" ]] \
      || _die "write needs --brand --org --repo --archetype"
    # Phase 7 origin-mesh (optional): shape-guard as a DNS label when present, so a
    # crafted value can never splice into base{} (it is _jesc'd too — defence in depth).
    [[ -z "$ORIGIN_MESH" || "$ORIGIN_MESH" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
      || _die "--origin-mesh '${ORIGIN_MESH}' is not a DNS label"
    # base-ref shape guard (same rule as the render/pull --ref flags): a crafted
    # value can never splice into base{} (it is _jesc'd too — defence in depth).
    if [[ -n "$BASE_REF" ]]; then
      [[ "$BASE_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,120}$ && "$BASE_REF" != *..* ]] \
        || _die "--base-ref '${BASE_REF}' is not a tag/branch/sha shape ([A-Za-z0-9._/-], no '..')"
    fi
    # producedAt: deterministic. Prefer explicit --produced-at, else SOURCE_DATE_EPOCH,
    # else the empty string (NEVER `date` now — that would break idempotency).
    if [[ -z "$PRODUCED_AT" && -n "${SOURCE_DATE_EPOCH:-}" ]]; then
      PRODUCED_AT="$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")"
    fi
    # identity: producer host/user is stable within a build host (idempotent on re-run).
    local_runner="$(id -un 2>/dev/null || echo unknown)@$(hostname 2>/dev/null || echo unknown)"
    {
      printf '{\n'
      printf '  "schema": "hugmesh.net/provenance/v1",\n'
      printf '  "base": {\n'
      printf '    "repo": "hugmesh-%s",\n' "$(_jesc "$REPO")"
      printf '    "commitSha": "%s",\n' "$(_jesc "$BASE_SHA")"
      # Versioned render (I5): base.ref is the tag/sha label the own-mesh base was
      # pulled at. OMITTED when empty so every pre-versioning manifest re-renders
      # byte-identical (determinism/idempotency contract, same as originMesh).
      if [[ -n "$BASE_REF" ]]; then
        printf '    "ref": "%s",\n' "$(_jesc "$BASE_REF")"
      fi
      # Phase 7: base.originMesh records the FOREIGN mesh a cross-mesh base came
      # from. OMITTED when empty (own mesh) so pre-Phase-7 manifests stay
      # byte-identical — determinism/idempotency contract preserved.
      if [[ -n "$ORIGIN_MESH" ]]; then
        printf '    "mode": "%s",\n' "$(_jesc "$BASE_MODE")"
        printf '    "originMesh": "%s"\n' "$(_jesc "$ORIGIN_MESH")"
      else
        printf '    "mode": "%s"\n' "$(_jesc "$BASE_MODE")"
      fi
      printf '  },\n'
      printf '  "template": {\n'
      printf '    "archetype": "%s",\n' "$(_jesc "$ARCHETYPE")"
      printf '    "recipeSha": "%s",\n' "$(_jesc "$RECIPE_SHA")"
      printf '    "generatorRepo": "%s",\n' "$(_jesc "$GEN_REPO")"
      printf '    "generatorCommit": "%s",\n' "$(_jesc "$GEN_COMMIT")"
      printf '    "engine": "%s"\n' "$(_jesc "$ENGINE")"
      printf '  },\n'
      printf '  "generator": {\n'
      printf '    "producedBy": "hugmesh-generator",\n'
      printf '    "runner": "%s",\n' "$(_jesc "$local_runner")"
      printf '    "producedAt": "%s"\n' "$(_jesc "$PRODUCED_AT")"
      printf '  },\n'
      printf '  "tenant": {\n'
      printf '    "brand": "%s",\n' "$(_jesc "$BRAND")"
      printf '    "org": "%s",\n' "$(_jesc "$ORG")"
      printf '    "clusterDomain": "%s"\n' "$(_jesc "$CLUSTER_DOMAIN")"
      printf '  }\n'
      printf '}\n'
    } > "${REPO_DIR}/${MANIFEST}"
    # Well-formedness self-check (fail-closed): a malformed manifest must never ship.
    if command -v jq >/dev/null 2>&1; then
      jq -e . "${REPO_DIR}/${MANIFEST}" >/dev/null 2>&1 || _die "emitted manifest is not valid JSON"
    fi
    _log "wrote ${REPO_DIR}/${MANIFEST}"
    ;;

  sign)
    [[ -f "${REPO_DIR}/${MANIFEST}" ]] || _die "no manifest at ${REPO_DIR}/${MANIFEST} (run write first)"
    [[ -n "$KEY" && -f "$KEY" ]] || _die "sign needs --key ED25519_PRIV.pem (out-of-band; never committed)"
    # Ed25519 one-shot over the canonical manifest bytes (rawin: no pre-hash).
    openssl pkeyutl -sign -inkey "$KEY" -rawin \
      -in "${REPO_DIR}/${MANIFEST}" -out "${REPO_DIR}/${SIG}" 2>/dev/null \
      || _die "ed25519 sign failed"
    _log "signed -> ${REPO_DIR}/${SIG} ($(wc -c < "${REPO_DIR}/${SIG}" | tr -d ' ') bytes, detached)"
    ;;

  verify)
    [[ -f "${REPO_DIR}/${MANIFEST}" ]] || _die "no manifest at ${REPO_DIR}/${MANIFEST}"
    [[ -f "${REPO_DIR}/${SIG}" ]] || _die "no signature at ${REPO_DIR}/${SIG}"
    [[ -n "$PUB" && -f "$PUB" ]] || _die "verify needs --pub ED25519_PUB.pem"
    if openssl pkeyutl -verify -pubin -inkey "$PUB" -rawin \
        -in "${REPO_DIR}/${MANIFEST}" -sigfile "${REPO_DIR}/${SIG}" >/dev/null 2>&1; then
      _log "OK: signature verifies for ${REPO_DIR}/${MANIFEST}"
    else
      _die "signature verification FAILED for ${REPO_DIR}/${MANIFEST}"
    fi
    ;;

  *) _die "usage: provenance.sh {write|sign|verify|keygen} ..." ;;
esac

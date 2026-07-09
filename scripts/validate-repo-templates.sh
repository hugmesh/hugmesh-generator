#!/usr/bin/env bash
# ============================================================================
# validate-repo-templates.sh — repo-overlay DRIFT guard (mesh templating pilot).
# ============================================================================
#
# Sibling to scripts/validate-reserved-prefixes.sh: a fail-loud drift check wired
# for CI. It proves the thin Tier-1 overlay (templates/repos/<repo>/) is STILL a
# faithful representation of the READ-ONLY Tier-2 base — i.e. the ONLY difference
# between the overlay and the current base is the 4 brand-coupled tokens.
#
# Mechanism (per overlaid file):
#   1. re-apply the overlay against a FRESHLY-pulled base, substituting the
#      UPSTREAM-IDENTITY token values (templates/repos/<repo>/_identity.env — the
#      base's OWN original literals) via the Phase-1 real-Handlebars renderer;
#   2. the result MUST be byte-identical to the base file. If not, the base has
#      DRIFTED (a non-templated line changed, or a templated line's surrounding
#      context moved) and the overlay must be refreshed. We fail loudly with:
#        * a PATCH-REJECT (unified diff of the drifted hunks), and
#        * an OVERLAYED-REGION CHECKSUM mismatch (sha256 rendered vs base).
#
# GREEN on a fresh, in-sync base; RED on any injected drift.
#
# Usage:
#   scripts/validate-repo-templates.sh [--repo login-ui] [--base DIR]
#
# --base DIR forces a specific read-only base; otherwise pull-repo-base.sh
# resolves it (set <NAME>_BASE_DIR to point at a present clone). BUILD-HOST ONLY
# (the renderer needs Node — see docs/MESH-TEMPLATING.md).
set -euo pipefail

_die() { echo "[validate-repo-templates] FATAL: $*" >&2; exit 2; }
_log() { echo "[validate-repo-templates] $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLING="${SCRIPT_DIR}/tooling"

REPO="login-ui"
BASE_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)  REPO="$2"; shift 2 ;;
    --base)  BASE_OVERRIDE="$2"; shift 2 ;;
    *) _die "unknown argument: $1" ;;
  esac
done

[[ "$REPO" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || _die "invalid --repo '$REPO'"
OVERLAY_DIR="${REPO_ROOT}/templates/repos/${REPO}"
[[ -d "$OVERLAY_DIR" ]] || _die "no overlay for repo '${REPO}' at ${OVERLAY_DIR}"
IDENTITY="${OVERLAY_DIR}/_identity.env"
[[ -f "$IDENTITY" ]] || _die "missing upstream-identity map: ${IDENTITY}"

command -v node >/dev/null 2>&1 || _die "node not found (build-host tool)"
[[ -d "${TOOLING}/node_modules/handlebars" ]] \
  || _die "handlebars not installed — run: (cd ${TOOLING} && npm install)"

# ── Resolve a FRESHLY-pulled read-only base ─────────────────────────────────
if [[ -n "$BASE_OVERRIDE" ]]; then
  [[ -d "$BASE_OVERRIDE" ]] || _die "--base '${BASE_OVERRIDE}' is not a directory"
  BASE="$(cd "$BASE_OVERRIDE" && pwd)"
else
  BASE="$("${SCRIPT_DIR}/pull-repo-base.sh" "$REPO")" \
    || _die "could not pull a base for '${REPO}' — cannot validate overlay drift"
fi
_log "validating overlay '${REPO}' against freshly-pulled base: ${BASE}"

# ── Load the upstream-identity token values (the drift oracle) ──────────────
# shellcheck source=/dev/null
source "$IDENTITY"
: "${BRAND_TITLE:?_identity.env must set BRAND_TITLE}"
: "${NPM_SCOPE:?_identity.env must set NPM_SCOPE}"
: "${HOST_NAME:?_identity.env must set HOST_NAME}"
: "${GENERATOR_ORG_GROUP:?_identity.env must set GENERATOR_ORG_GROUP}"
export BRAND_TITLE NPM_SCOPE HOST_NAME GENERATOR_ORG_GROUP

# ── Stage + render the overlay with UPSTREAM-IDENTITY values ────────────────
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STAGE="${TMP}/overlay"; RENDERED="${TMP}/rendered"; mkdir -p "$STAGE" "$RENDERED"
while IFS= read -r -d '' t; do
  rel="${t#"${OVERLAY_DIR}/"}"
  mkdir -p "${STAGE}/$(dirname "$rel")"
  cp "$t" "${STAGE}/${rel}"
done < <(find "$OVERLAY_DIR" -name '*.hbs' -not -path '*/_skeleton/*' -print0)

node "${TOOLING}/render-handlebars.js" \
    --templates "$STAGE" --out "$RENDERED" \
    --extra-tokens "NPM_SCOPE,HOST_NAME,GENERATOR_ORG_GROUP" >&2

# ── Byte-compare each re-applied overlay file to the base (patch-reject + sum) ─
echo "== login-ui overlay drift check =="
echo "repo              : ${REPO}"
echo "base              : ${BASE}"
echo "overlaid files    : $(find "$RENDERED" -type f | wc -l | tr -d ' ')"
echo ""

FAILED=0
while IFS= read -r -d '' r; do
  rel="${r#"${RENDERED}/"}"
  base_file="${BASE}/${rel}"
  if [[ ! -f "$base_file" ]]; then
    echo "  [MISSING] ${rel} — overlay targets a file absent from the base"
    FAILED=1
    continue
  fi
  sum_rendered="$(sha256sum "$r" | awk '{print $1}')"
  sum_base="$(sha256sum "$base_file" | awk '{print $1}')"
  if [[ "$sum_rendered" == "$sum_base" ]]; then
    echo "  [OK]      ${rel}"
    echo "              overlayed-region checksum: ${sum_base:0:16}… (matches base)"
  else
    FAILED=1
    echo "  [DRIFT]   ${rel}"
    echo "              overlayed-region checksum MISMATCH:"
    echo "                base     = ${sum_base}"
    echo "                overlay  = ${sum_rendered}"
    echo "              patch-reject (base <-> re-applied overlay@upstream-identity):"
    diff -u "$base_file" "$r" | sed 's/^/                /' || true
  fi
done < <(find "$RENDERED" -type f -print0)

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo "RESULT: PASS — overlay is in sync with the base (0 drift)."
  exit 0
else
  echo "RESULT: FAIL — overlay has DRIFTED from the base (see patch-rejects above)." >&2
  echo "Refresh templates/repos/${REPO}/*.hbs (and _identity.env) against the new base." >&2
  exit 1
fi

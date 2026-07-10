#!/usr/bin/env bash
# ============================================================================
# render-handlebars.sh — shell wrapper for the REAL Handlebars renderer.
# ============================================================================
#
#  >>> BUILD-HOST ONLY. This invokes `node`, which MUST NOT run as root on <<<
#  >>> the mesh-node fail-closed root-cron reconcile path (Phase 6). See    <<<
#  >>> docs/MESH-TEMPLATING.md, "Node-not-root-on-the-mesh-cron-path".      <<<
#
# Opt-in Handlebars counterpart to the DEFAULT sed renderer in
# generate-brand-repos.sh. It sources the brand .conf and derives HARBOR_PROJECT
# with the SAME slug logic generate-brand-repos.sh uses, so the render context is
# byte-identical, then hands off to render-handlebars.js.
#
# Output layout mirrors generate-brand-repos.sh exactly:
#   <out-dir>/<BRAND>-gitops/apps/*.yaml
# so scripts/parity-gate.sh can diff the two trees directly.
#
# Usage:
#   scripts/tooling/render-handlebars.sh brands/example.conf [--out-dir DIR]

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TOOLING_DIR}/../.." && pwd)"
TEMPLATES_DIR="${REPO_ROOT}/templates"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <brands/BRAND.conf> [--out-dir DIR]" >&2
  exit 1
fi

BRAND_CONF="$1"
OUT_DIR="./out"
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$BRAND_CONF" ]]; then
  echo "Brand config not found: $BRAND_CONF" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "[render-handlebars] FATAL: node not found (build-host tool)" >&2
  exit 1
fi
if [[ ! -d "${TOOLING_DIR}/node_modules/handlebars" ]]; then
  echo "[render-handlebars] FATAL: handlebars not installed — run: (cd ${TOOLING_DIR} && npm install)" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$BRAND_CONF"

: "${BRAND:?brand config must set BRAND}"
: "${BRAND_TITLE:?brand config must set BRAND_TITLE}"
: "${ORG:?brand config must set ORG}"
: "${CLUSTER_DOMAIN:?brand config must set CLUSTER_DOMAIN}"
# HEADSCALE_URL / MESH_TAG may be empty in local-first profiles.
: "${HEADSCALE_URL:=}"
: "${MESH_TAG:=}"

# Derive HARBOR_PROJECT identically to generate-brand-repos.sh (single source of
# the slug rule; keep in sync if that derivation ever changes).
HARBOR_PROJECT="${ORG,,}"
HARBOR_PROJECT="${HARBOR_PROJECT//[^a-z0-9-]/-}"
HARBOR_PROJECT="$(echo "$HARBOR_PROJECT" | sed 's/^-*//; s/-*$//')"

# Derive NS_PREFIX identically to generate-brand-repos.sh (defaults to the BRAND
# slug; a brand profile may override by setting NS_PREFIX). Referenced by the
# brand-repo ApplicationSet templates/apps/13d-brand-repos.yaml.hbs. Keep in sync.
NS_PREFIX="${NS_PREFIX:-$BRAND}"

BRAND_OUT="${OUT_DIR}/${BRAND}-gitops"

export BRAND BRAND_TITLE ORG CLUSTER_DOMAIN HEADSCALE_URL HARBOR_PROJECT MESH_TAG NS_PREFIX

exec node "${TOOLING_DIR}/render-handlebars.js" \
  --templates "$TEMPLATES_DIR" \
  --out "$BRAND_OUT"

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

# Security-posture knobs come from the BRAND PROFILE only — reset before source
# so an ambient exported MFA cannot leak into the render (mirrors
# generate-brand-repos.sh; keep IN SYNC or scripts/parity-gate.sh diverges).
MFA=""
# Same rule for the per-domain IdP choice (issue #47) and its Casdoor org
# (mirrors generate-brand-repos.sh — keep IN SYNC).
IDP=""
CASDOOR_ORG=""
# shellcheck source=/dev/null
source "$BRAND_CONF"

: "${BRAND:?brand config must set BRAND}"
: "${BRAND_TITLE:?brand config must set BRAND_TITLE}"
: "${ORG:?brand config must set ORG}"
: "${CLUSTER_DOMAIN:?brand config must set CLUSTER_DOMAIN}"
# HEADSCALE_URL / MESH_TAG may be empty in local-first profiles.
: "${HEADSCALE_URL:=}"
: "${MESH_TAG:=}"

# ── Fail-closed scalar validation ──────────────────────────────────────────────
# This opt-in `--engine handlebars` path feeds BRAND/ORG/CLUSTER_DOMAIN/BRAND_TITLE/NS_PREFIX,
# UNESCAPED (render-handlebars.js sets noEscape:true), into generated gateway route/host YAML.
# The DEFAULT sed engine (generate-brand-repos.sh) already validates these fail-closed; without
# the same guards here a newline/metachar-bearing CLUSTER_DOMAIN (etc.) injects or corrupts the
# ingress host + route config. Mirrors generate-brand-repos.sh — keep IN SYNC (each brand script
# in this tree carries its own copy of these guards).
_DNS_LABEL='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
_DNS_NAME='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'
_hbdie() { echo "[render-handlebars] FATAL: $*" >&2; exit 1; }
[[ "$BRAND" =~ $_DNS_LABEL ]] \
  || _hbdie "invalid BRAND '${BRAND}' (must be a DNS label)"
[[ "$ORG" =~ ^[A-Za-z0-9._-]{1,63}$ ]] \
  || _hbdie "invalid ORG '${ORG}' (allowed: A-Za-z0-9._- , 1..63)"
[[ "$CLUSTER_DOMAIN" =~ $_DNS_NAME ]] \
  || _hbdie "invalid CLUSTER_DOMAIN '${CLUSTER_DOMAIN}' (must be a DNS name)"
if [ -n "$MESH_TAG" ]; then
  [[ "$MESH_TAG" =~ ^tag:[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
    || _hbdie "invalid MESH_TAG '${MESH_TAG}' (must be 'tag:<dns-label>')"
fi
if [ -n "$HEADSCALE_URL" ]; then
  [[ "$HEADSCALE_URL" =~ ^https?://[A-Za-z0-9._~:/?#@!$()*,=%+-]+$ ]] \
    || _hbdie "invalid HEADSCALE_URL '${HEADSCALE_URL}'"
fi
[ -n "$BRAND_TITLE" ] || _hbdie "BRAND_TITLE must not be empty"
case "$BRAND_TITLE" in
  *['"\$`|&']* ) _hbdie "invalid BRAND_TITLE (forbidden chars: \" \\ \$ \` | &)" ;;
esac
case "$BRAND_TITLE" in
  *['{}']* ) _hbdie "invalid BRAND_TITLE (braces forbidden — no template-token injection)" ;;
esac
if [[ "$BRAND_TITLE" == *$'\n'* || "$BRAND_TITLE" == *$'\r'* ]]; then
  _hbdie "invalid BRAND_TITLE (must be single-line)"
fi

# Derive HARBOR_PROJECT identically to generate-brand-repos.sh (single source of
# the slug rule; keep in sync if that derivation ever changes).
HARBOR_PROJECT="${ORG,,}"
HARBOR_PROJECT="${HARBOR_PROJECT//[^a-z0-9-]/-}"
HARBOR_PROJECT="$(echo "$HARBOR_PROJECT" | sed 's/^-*//; s/-*$//')"

# Derive NS_PREFIX identically to generate-brand-repos.sh (defaults to the BRAND
# slug; a brand profile may override by setting NS_PREFIX). Referenced by the
# brand-repo ApplicationSet templates/apps/13d-brand-repos.yaml.hbs. Keep in sync.
NS_PREFIX="${NS_PREFIX:-$BRAND}"
[[ "$NS_PREFIX" =~ $_DNS_LABEL ]] \
  || _hbdie "invalid NS_PREFIX '${NS_PREFIX}' (must be a DNS label)"

# Derive MFA_ENABLED identically to generate-brand-repos.sh (per-domain gateway
# MFA flip, issue #47; fail closed on unknown spellings). Keep in sync — the
# parity gate byte-compares the two engines' output.
case "${MFA}" in
  ""|0|false|off) MFA_ENABLED="false" ;;
  1|true|on)      MFA_ENABLED="true" ;;
  *) _hbdie "invalid MFA '${MFA}' in the brand profile (use MFA=1 to enable; unset/0/false/off = disabled)" ;;
esac

# Derive IDP / CASDOOR_ORG / ORG_SLUG identically to generate-brand-repos.sh
# (per-domain IdP choice, issue #47; fail closed on unknown spellings). Keep in
# sync — the parity gate byte-compares the two engines' output, including an
# IDP=own leg.
case "${IDP}" in
  ""|superdomain) IDP="superdomain" ;;
  own)            IDP="own" ;;
  *) _hbdie "invalid IDP '${IDP}' in the brand profile (use IDP=own for a per-domain Casdoor; unset/superdomain = the central IdP)" ;;
esac
CASDOOR_ORG="${CASDOOR_ORG:-$BRAND}"
[[ "$CASDOOR_ORG" =~ $_DNS_LABEL ]] \
  || _hbdie "invalid CASDOOR_ORG '${CASDOOR_ORG}' (must be a DNS label)"
ORG_SLUG="${ORG,,}"
ORG_SLUG="${ORG_SLUG//[^a-z0-9-]/-}"
ORG_SLUG="$(echo "$ORG_SLUG" | sed 's/^-*//; s/-*$//')"

# The own-Casdoor templates render ONLY for an IDP=own brand — mirror
# generate-brand-repos.sh's _idp_gated_template() prefixes VERBATIM (keep the
# two lists in sync or the parity gate diverges).
SKIP_ARGS=()
if [[ "$IDP" != "own" ]]; then
  SKIP_ARGS=(--skip-prefixes "apps/05-casdoor.yaml.hbs,manifests/casdoor/")
fi

BRAND_OUT="${OUT_DIR}/${BRAND}-gitops"

export BRAND BRAND_TITLE ORG CLUSTER_DOMAIN HEADSCALE_URL HARBOR_PROJECT MESH_TAG NS_PREFIX MFA_ENABLED CASDOOR_ORG ORG_SLUG

exec node "${TOOLING_DIR}/render-handlebars.js" \
  --templates "$TEMPLATES_DIR" \
  --out "$BRAND_OUT" \
  ${SKIP_ARGS[@]+"${SKIP_ARGS[@]}"}

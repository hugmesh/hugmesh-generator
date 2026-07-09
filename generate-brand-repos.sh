#!/usr/bin/env bash
# generate-brand-repos.sh — render Handlebars-style (.hbs) templates for a brand
# and produce a self-contained GitOps repo ready to push to GitLab + register in ArgoCD.
#
# Usage:
#   ./generate-brand-repos.sh brands/example.conf [--out-dir ./out]
#
# The output directory will contain a directory named <BRAND>-gitops/ with all
# rendered Application CRDs under apps/. Push that directory to GitLab and the
# ArgoCD app-of-apps root Application (specs/cluster/apps/00-app-of-apps-waved.yaml
# — a plain directory.recurse Application named snapdragon-root-waved, NOT an
# ApplicationSet) will pick it up once registered.
#
# No external tools required beyond bash + sed + git.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# ── Parse arguments ─────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <brands/BRAND.conf> [--out-dir DIR]" >&2
  exit 1
fi

BRAND_CONF="$1"
OUT_DIR="./out"
# ENGINE: sed (DEFAULT, unchanged behavior — no external tools) | handlebars
# (opt-in; delegates to the REAL Handlebars renderer under scripts/tooling/,
# proven byte-identical to sed by scripts/parity-gate.sh). BUILD-HOST ONLY —
# the handlebars path needs Node, which must NOT run as root on the mesh-node
# cron path (see docs/MESH-TEMPLATING.md).
ENGINE="sed"

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --engine=*) ENGINE="${1#*=}"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$BRAND_CONF" ]]; then
  echo "Brand config not found: $BRAND_CONF" >&2
  exit 1
fi

# Opt-in Handlebars path: delegate to the wrapper and return. The DEFAULT sed
# path below is untouched.
case "$ENGINE" in
  sed) : ;;
  handlebars)
    exec "${SCRIPT_DIR}/scripts/tooling/render-handlebars.sh" "$BRAND_CONF" --out-dir "$OUT_DIR" ;;
  *) echo "Unknown --engine '$ENGINE' (want: sed | handlebars)" >&2; exit 1 ;;
esac

# ── Load brand config ─────────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "$BRAND_CONF"

: "${BRAND:?brand config must set BRAND}"
: "${BRAND_TITLE:?brand config must set BRAND_TITLE}"
: "${ORG:?brand config must set ORG}"
: "${CLUSTER_DOMAIN:?brand config must set CLUSTER_DOMAIN}"
: "${HEADSCALE_URL:?brand config must set HEADSCALE_URL}"
: "${MESH_TAG:?brand config must set MESH_TAG}"

# ── Validate the sourced brand fields (#15/#8/#12) ─────────────────────────────
# The brand profile is, on a mesh node, SYNTHESISED by snapdragon-domain-reconcile
# from the SIGNED cross-domain #118 export — verified for AUTHENTICITY but NOT for
# CONTENT. BRAND is then built into filesystem paths (BRAND_OUT below -> rm -rf /
# mkdir / file writes, all as root from the reconcile cron) and every field lands
# RAW on a `sed s|…|VALUE|` replacement in render_template. So a value containing
# '/'/'..' (path traversal) or a sed metachar ('|' '&' '\\' / newline) is unsafe.
# Fail closed BEFORE any filesystem or sed use; legit slugs/domains still pass.
_DNS_LABEL='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
_DNS_NAME='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'
_die() { echo "[generate-brand-repos] FATAL: $*" >&2; exit 1; }

# Slug allowlist (single DNS label) — used for BRAND (becomes a path component).
[[ "$BRAND" =~ $_DNS_LABEL ]] \
  || _die "invalid BRAND '${BRAND}' (must be a DNS label: ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\$)"
# ORG is also lowercased->slugged below; require it to be safe to slug.
[[ "$ORG" =~ ^[A-Za-z0-9._-]{1,63}$ ]] \
  || _die "invalid ORG '${ORG}' (allowed: A-Za-z0-9._- , 1..63)"
# CLUSTER_DOMAIN: full DNS name (e.g. snapdragon.systems).
[[ "$CLUSTER_DOMAIN" =~ $_DNS_NAME ]] \
  || _die "invalid CLUSTER_DOMAIN '${CLUSTER_DOMAIN}' (must be a DNS name)"
# RELEASE_STATE: "internal" (DEFAULT, LAN/tailnet-only) or "public" (internet-
# facing) — gates the ingress-class/NetworkPolicy posture baked by gate_env_apps()
# and the host nftables firewall in the build-*-stage4.sh scripts. public makes
# no sense paired with a non-routable *.test/*.internal CLUSTER_DOMAIN.
if [[ "${RELEASE_STATE:-internal}" == "public" && "$CLUSTER_DOMAIN" =~ \.(test|internal)$ ]]; then
  _die "invalid RELEASE_STATE 'public' with CLUSTER_DOMAIN '${CLUSTER_DOMAIN}' (a *.test/*.internal domain is not public-routable; use RELEASE_STATE=internal or set a real CLUSTER_DOMAIN)"
fi
# MESH_TAG: headscale ACL tag form 'tag:<slug>'.
_RE_MESH='^tag:[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
[[ "$MESH_TAG" =~ $_RE_MESH ]] \
  || _die "invalid MESH_TAG '${MESH_TAG}' (must be 'tag:<dns-label>')"
# HEADSCALE_URL: http(s) URL, no shell/sed metachars (|, &, backtick, quotes) or
# whitespace. Pattern held in a var so the literal regex is not re-parsed by [[.
_RE_URL='^https?://[A-Za-z0-9._~:/?#@!$()*,=%+-]+$'
[[ "$HEADSCALE_URL" =~ $_RE_URL ]] \
  || _die "invalid HEADSCALE_URL '${HEADSCALE_URL}'"
# BRAND_TITLE is free-text but reaches a sourced/sed context: forbid the chars
# that break a sed replacement or a shell assignment (quote/backslash/dollar/
# backtick/newline/pipe/ampersand). Printable, length-bounded.
[ -n "$BRAND_TITLE" ] || _die "BRAND_TITLE must not be empty"
case "$BRAND_TITLE" in
  *['"\$`|&']* ) _die "invalid BRAND_TITLE (forbidden chars: \" \\ \$ \` | &)" ;;
esac
# Reject any newline (or other control char) — must be a single printable line.
if [[ "$BRAND_TITLE" == *$'\n'* || "$BRAND_TITLE" == *$'\r'* ]]; then
  _die "invalid BRAND_TITLE (must be single-line)"
fi
[[ "${#BRAND_TITLE}" -le 128 ]] || _die "BRAND_TITLE too long (max 128)"

# ── Derived variables ─────────────────────────────────────────────────────────
# GITLAB_GROUP: lowercase slug of ORG for the tenant's OWN GitOps repo's GitLab
# hosting path (see the "git remote add origin https://gitlab.${CLUSTER_DOMAIN}/
# ${GITLAB_GROUP}/..." line below) — this is genuinely a GitLab-group concept
# (where the generated *-gitops repo itself lives), unrelated to container images.
GITLAB_GROUP="${ORG,,}"
GITLAB_GROUP="${GITLAB_GROUP//[^a-z0-9-]/-}"
# Strip leading/trailing hyphens and collapse runs
GITLAB_GROUP="$(echo "$GITLAB_GROUP" | sed 's/^-*//; s/-*$//')"

# HARBOR_PROJECT: same slugging as GITLAB_GROUP above, but for the {{HARBOR_PROJECT}}
# template token — the Harbor PROJECT namespace first-party container images are
# pushed/pulled under (newName: registry.{{CLUSTER_DOMAIN}}/{{HARBOR_PROJECT}}/...).
# Deliberately a SEPARATE variable from GITLAB_GROUP even though they compute the
# same value today: one names a GitLab hosting group, the other a Harbor registry
# project — conflating them was the pre-migration naming (formerly {{GITLAB_GROUP}}
# reused for both), renamed here so the two concerns can diverge independently.
HARBOR_PROJECT="${ORG,,}"
HARBOR_PROJECT="${HARBOR_PROJECT//[^a-z0-9-]/-}"
HARBOR_PROJECT="$(echo "$HARBOR_PROJECT" | sed 's/^-*//; s/-*$//')"

echo "[generate-brand-repos] Brand:         ${BRAND}"
echo "[generate-brand-repos] Title:         ${BRAND_TITLE}"
echo "[generate-brand-repos] Org:           ${ORG}"
echo "[generate-brand-repos] Domain:        ${CLUSTER_DOMAIN}"
echo "[generate-brand-repos] GitLab group:  ${GITLAB_GROUP}"
echo "[generate-brand-repos] Harbor project: ${HARBOR_PROJECT}"
echo "[generate-brand-repos] Headscale:     ${HEADSCALE_URL}"
echo "[generate-brand-repos] Mesh tag:      ${MESH_TAG}"
echo ""

# Escape a string for the REPLACEMENT side of `sed s|...|...|` (mirrors the
# _sed_rep_escape helper in specs/usr/sbin/snapdragon-branding): backslash first,
# then the ampersand (whole-match) and the `|` delimiter. Defense-in-depth on top
# of the up-front allowlist above (the validated fields contain none of these, but
# the escaping keeps the sink itself safe).
_sed_rep_escape() {
  local s="$1"
  s="${s//\\/\\\\}"   # \  -> \\
  s="${s//&/\\&}"     # &  -> \&
  s="${s//|/\\|}"     # |  -> \|
  printf '%s' "${s}"
}

# ── Template renderer ─────────────────────────────────────────────────────────
render_template() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  # Replace {{PLACEHOLDER}} tokens with brand values.
  # Ordering matters: longer/more-specific tokens first to avoid partial matches.
  sed \
    -e "s|{{BRAND_TITLE}}|$(_sed_rep_escape "${BRAND_TITLE}")|g" \
    -e "s|{{CLUSTER_DOMAIN}}|$(_sed_rep_escape "${CLUSTER_DOMAIN}")|g" \
    -e "s|{{HEADSCALE_URL}}|$(_sed_rep_escape "${HEADSCALE_URL}")|g" \
    -e "s|{{HARBOR_PROJECT}}|$(_sed_rep_escape "${HARBOR_PROJECT}")|g" \
    -e "s|{{MESH_TAG}}|$(_sed_rep_escape "${MESH_TAG}")|g" \
    -e "s|{{BRAND}}|$(_sed_rep_escape "${BRAND}")|g" \
    -e "s|{{ORG}}|$(_sed_rep_escape "${ORG}")|g" \
    "$src" > "$dst"
}

# ── Output directory ──────────────────────────────────────────────────────────
BRAND_OUT="${OUT_DIR}/${BRAND}-gitops"
# Defense-in-depth on top of the BRAND slug allowlist: assert BRAND_OUT resolves
# STRICTLY under OUT_DIR before the destructive rm -rf / mkdir, so even a future
# regression in the allowlist cannot escape the staging dir.
_out_abs="$(mkdir -p "$OUT_DIR" 2>/dev/null; realpath -m -- "$OUT_DIR")"
_brand_out_abs="$(realpath -m -- "$BRAND_OUT")"
case "$_brand_out_abs/" in
  "$_out_abs"/*) : ;;
  *) _die "refusing to operate outside OUT_DIR: '${BRAND_OUT}' resolves to '${_brand_out_abs}' (not under '${_out_abs}')" ;;
esac
if [[ -d "$BRAND_OUT" ]]; then
  echo "[generate-brand-repos] Removing existing output: $BRAND_OUT"
  rm -rf "$BRAND_OUT"
fi
mkdir -p "$BRAND_OUT"

# ── Render .hbs templates ─────────────────────────────────────────────────────
rendered=0
while IFS= read -r -d '' tmpl; do
  rel="${tmpl#"${TEMPLATES_DIR}/"}"
  # Strip .hbs suffix for the output filename
  out_rel="${rel%.hbs}"
  out="${BRAND_OUT}/${out_rel}"
  render_template "$tmpl" "$out"
  echo "  rendered: ${out_rel}"
  rendered=$((rendered + 1))
done < <(find "$TEMPLATES_DIR" -path "$TEMPLATES_DIR/repos" -prune -o -name "*.hbs" -print0 | sort -z)

# ── Copy non-template static files ───────────────────────────────────────────
while IFS= read -r -d '' f; do
  rel="${f#"${TEMPLATES_DIR}/"}"
  dst="${BRAND_OUT}/${rel}"
  mkdir -p "$(dirname "$dst")"
  cp "$f" "$dst"
done < <(find "$TEMPLATES_DIR" -path "$TEMPLATES_DIR/repos" -prune -o \( -not -name "*.hbs" -not -type d -print0 \))

echo ""
echo "[generate-brand-repos] Rendered ${rendered} templates → ${BRAND_OUT}"
echo ""
echo "Next steps:"
echo "  1. Review the output:  ls ${BRAND_OUT}/apps/"
echo "  2. Init and push:"
echo "     cd ${BRAND_OUT}"
echo "     git init -b main"
echo "     git add apps/"
echo "     git commit -m 'Initial ${BRAND} GitOps — generated by snapdragon-generator'"
echo "     git remote add origin https://gitlab.${CLUSTER_DOMAIN}/${GITLAB_GROUP}/${BRAND}-gitops.git"
echo "     git push -u origin main"
echo "  3. Register in ArgoCD: add an Application pointing at the ${BRAND}-gitops repo"
echo "     or add it to the ApplicationSet source list once PR7 is merged."

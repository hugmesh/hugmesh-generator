#!/usr/bin/env bash
# ============================================================================
# parity-gate.sh — EXIT CRITERION for the mesh templating pilot (Phase 1).
# ============================================================================
#
# Renders the 13 ArgoCD Application CRDs BOTH ways — the DEFAULT sed renderer
# (generate-brand-repos.sh) and the opt-in REAL Handlebars renderer
# (scripts/tooling/render-handlebars.sh) — for brands/example.conf AND
# brands/local.conf, then asserts the two output trees are BYTE-IDENTICAL.
#
# sed stays the default; Handlebars is proven to be a drop-in before anything
# else in the pilot builds on it. Non-zero exit = parity broken = STOP.
#
# NOTE on local.conf normalization: generate-brand-repos.sh requires a non-empty,
# URL-shaped HEADSCALE_URL (and a tag-shaped MESH_TAG) — a prod-oriented field
# check. brands/local.conf is local-first and leaves HEADSCALE_URL empty. Those
# two tokens are DEAD (they appear in none of the 13 templates), so to compare
# the renderers apples-to-apples this gate feeds BOTH the exact same normalized
# conf (a placeholder is appended only when empty). The comparison stays honest:
# identical context in, byte-compared out.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BRANDS=("brands/example.conf" "brands/local.conf")
FAILED=0

# Emit a normalized copy of a brand conf that satisfies generate-brand-repos.sh's
# required-field validation (HEADSCALE_URL, MESH_TAG) using placeholders derived
# from the brand's own fields. Both renderers consume THIS file.
normalize_conf() {
  local src="$1" dst="$2"
  cp "$src" "$dst"
  # Read the effective values in an isolated subshell.
  local hs tag dom brand
  # shellcheck source=/dev/null
  hs="$(set +u; source "$src"; printf '%s' "${HEADSCALE_URL:-}")"
  tag="$(set +u; source "$src"; printf '%s' "${MESH_TAG:-}")"
  dom="$(set +u; source "$src"; printf '%s' "${CLUSTER_DOMAIN:-}")"
  brand="$(set +u; source "$src"; printf '%s' "${BRAND:-}")"
  if [[ -z "$hs" ]]; then
    printf '\nHEADSCALE_URL="https://headscale.%s"\n' "$dom" >> "$dst"
  fi
  if [[ -z "$tag" ]]; then
    printf 'MESH_TAG="tag:%s"\n' "$brand" >> "$dst"
  fi
}

echo "=============================================================="
echo " mesh templating parity gate: sed (default) vs Handlebars"
echo "=============================================================="

for conf in "${BRANDS[@]}"; do
  name="$(basename "$conf" .conf)"
  norm="${WORK}/${name}.conf"
  normalize_conf "$conf" "$norm"

  # Discover the BRAND slug (that is the output subdir name) from the norm conf.
  brand_slug="$(set +u; source "$norm"; printf '%s' "$BRAND")"

  sed_out="${WORK}/${name}/sed"
  hbs_out="${WORK}/${name}/hbs"
  mkdir -p "$sed_out" "$hbs_out"

  echo ""
  echo "--- brand '${name}' (BRAND=${brand_slug}) ---"
  ./generate-brand-repos.sh "$norm" --out-dir "$sed_out" >/dev/null
  # stderr is CAPTURED, not discarded: with 2>/dev/null a missing node dep (or any
  # renderer crash) was a bare exit-1 with zero diagnostics — the gate said FAIL
  # and nothing said why. Surface the renderer's own words on failure.
  if ! scripts/tooling/render-handlebars.sh "$norm" --out-dir "$hbs_out" 2>"${hbs_out}/.render-stderr"; then
    echo "  FAIL handlebars renderer exited nonzero for brand '${name}':"
    sed 's/^/        /' "${hbs_out}/.render-stderr" | tail -20
    exit 1
  fi
  rm -f "${hbs_out}/.render-stderr"

  sed_tree="${sed_out}/${brand_slug}-gitops"
  hbs_tree="${hbs_out}/${brand_slug}-gitops"

  n_sed="$(find "$sed_tree" -type f | wc -l | tr -d ' ')"
  n_hbs="$(find "$hbs_tree" -type f | wc -l | tr -d ' ')"

  if diff -r "$sed_tree" "$hbs_tree" >"${WORK}/${name}.diff" 2>&1; then
    echo "  sed files: ${n_sed}   handlebars files: ${n_hbs}"
    echo "  RESULT: BYTE-IDENTICAL [OK]"
  else
    echo "  RESULT: MISMATCH [FAIL] -- diff follows:"
    sed 's/^/    /' "${WORK}/${name}.diff"
    FAILED=1
  fi
done

echo ""
echo "=============================================================="
if [[ "$FAILED" -eq 0 ]]; then
  echo " PARITY GATE: PASS (all brands byte-identical across renderers)"
  echo "=============================================================="
  exit 0
else
  echo " PARITY GATE: FAIL"
  echo "=============================================================="
  exit 1
fi

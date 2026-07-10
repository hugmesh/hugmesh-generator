#!/usr/bin/env bash
# ============================================================================
# render-tenant-set.sh — one-command FULL tenant-set render (opt-in wrapper).
# ============================================================================
#
#  >>> BUILD-HOST ONLY. Invokes node; MUST NOT run as root on the mesh-node     <<<
#  >>> fail-closed root-cron reconcile path (Phase 6). See docs/MESH-TEMPLATING.md.
#
# Thin gate over scripts/tooling/render-tenant-set.js: renders every installed
# repo in a structured brand YAML's repos[] manifest (repo -> archetype ->
# archetype overlay + per-repo identity), with two-tier skeleton fallback.
#
# Usage:
#   scripts/render-tenant-set.sh brands/<brand>.yaml --enable-repo-tree \
#       [--out-dir DIR] [--offline] [--only a,b]
#
# --enable-repo-tree is REQUIRED (opt-in; this path is additive and never part of
# the default sed cluster-manifest render).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLING="${SCRIPT_DIR}/tooling"

[[ $# -ge 1 ]] || { echo "usage: $0 brands/<brand>.yaml --enable-repo-tree [--out-dir DIR] [--offline] [--only a,b]" >&2; exit 2; }
YAML="$1"; shift

ENABLED=0
PASS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --enable-repo-tree) ENABLED=1; shift ;;
    *) PASS+=("$1"); shift ;;
  esac
done
if [[ "$ENABLED" -ne 1 ]]; then
  echo "[render-tenant-set] OPT-IN GATE: pass --enable-repo-tree to run (build-host only)." >&2
  exit 2
fi

command -v node >/dev/null 2>&1 || { echo "[render-tenant-set] FATAL: node not found (build-host tool)" >&2; exit 1; }
[[ -d "${TOOLING}/node_modules/handlebars" && -d "${TOOLING}/node_modules/js-yaml" ]] \
  || { echo "[render-tenant-set] FATAL: deps missing — run: (cd ${TOOLING} && npm install)" >&2; exit 1; }

exec node "${TOOLING}/render-tenant-set.js" "$YAML" ${PASS[@]+"${PASS[@]}"}

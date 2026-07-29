#!/usr/bin/env bash
# =============================================================================
# sync-reserved-configmap.sh — regenerate the in-cluster reserved-prefixes
# ConfigMap's `reserved.json` from the canonical source of truth so the two
# never drift. Run this after editing specs/cluster/reserved-prefixes.yaml.
#
#   specs/cluster/reserved-prefixes.yaml   (spec.reserved)   <-- SOURCE
#       -> manifests/policy/reserved-prefixes-configmap.yaml  (data['reserved.json'])
#
# scripts/validate-reserved-prefixes.sh then asserts they match (and that the
# set covers every deployed gateway route prefix). Idempotent; rewrites only the
# reserved.json line in place.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CANONICAL="${REPO_ROOT}/specs/cluster/reserved-prefixes.yaml"
CONFIGMAP="${REPO_ROOT}/specs/cluster/manifests/policy/reserved-prefixes-configmap.yaml"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }

python3 - "$CANONICAL" "$CONFIGMAP" <<'PY'
import json, sys, yaml

canonical_path, configmap_path = sys.argv[1:3]

reserved = yaml.safe_load(open(canonical_path))["spec"]["reserved"]
# Canonical, deterministic ordering for the in-cluster JSON: sorted set.
reserved = sorted(set(reserved))
new_json = json.dumps(reserved, separators=(",", ":"))

lines = open(configmap_path).read().splitlines(keepends=True)
out, replaced = [], False
for line in lines:
    stripped = line.lstrip()
    if stripped.startswith("[") and stripped.rstrip().endswith("]"):
        indent = line[: len(line) - len(stripped)]
        out.append(f"{indent}{new_json}\n")
        replaced = True
    else:
        out.append(line)

if not replaced:
    print("FATAL: could not find the reserved.json array line to replace in "
          f"{configmap_path}", file=sys.stderr)
    sys.exit(2)

open(configmap_path, "w").writelines(out)
print(f"synced {len(reserved)} labels -> {configmap_path}")
PY

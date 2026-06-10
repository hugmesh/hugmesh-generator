#!/usr/bin/env bash
# =============================================================================
# validate-reserved-prefixes.sh — route-federation consistency / drift guard.
# =============================================================================
# Asserts that the CANONICAL reserved-prefix set
# (specs/cluster/reserved-prefixes.yaml) is a SUPERSET of every dedicated route
# prefix / reserved subdomain actually deployed by the GitOps tree, i.e.:
#
#   reserved  ⊇  { first path-segment of every gateway route (apps/20-gateway-*.yaml) }
#               ∪ { first DNS label of every reserved gateway host / extraHost }
#               ∪ { first segment of every gateway_route_access.url_pattern (schema.sql) }
#
# If a NEW dedicated route prefix is added (to a gateway app or the route-access
# seed) without also reserving it, this check FAILS — catching the drift that
# would let a vanity username collide with a real platform route.
#
# It ALSO asserts the in-cluster ConfigMap mirror
# (manifests/policy/reserved-prefixes-configmap.yaml) matches the canonical
# source exactly, so the Kyverno policy and the GitOps list cannot drift.
#
# Wired into .gitlab-ci.yml (lint stage). Uses python3 + PyYAML (present in CI)
# for robust YAML parsing; degrades to a clear error if python3/PyYAML is absent.
#
# Exit 0 = consistent; non-zero = drift / mismatch (prints the offending labels).
set -euo pipefail

# Repo-root-relative paths (resolve from this script's location).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CANONICAL="${REPO_ROOT}/specs/cluster/reserved-prefixes.yaml"
CONFIGMAP="${REPO_ROOT}/specs/cluster/manifests/policy/reserved-prefixes-configmap.yaml"
SCHEMA_SQL="${REPO_ROOT}/specs/cluster/manifests/route-access/initdb/20-schema.sql"
GATEWAY_GLOB="${REPO_ROOT}/specs/cluster/apps"

for f in "$CANONICAL" "$CONFIGMAP" "$SCHEMA_SQL"; do
  [[ -f "$f" ]] || { echo "FATAL: missing required file: $f" >&2; exit 2; }
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: python3 is required to parse the gateway YAML." >&2
  exit 2
fi

# Hand off to python for the actual set-logic (YAML + SQL parsing). The script
# prints a human report and exits non-zero on any violation.
python3 - "$CANONICAL" "$CONFIGMAP" "$SCHEMA_SQL" "$GATEWAY_GLOB" <<'PY'
import glob
import json
import os
import re
import sys

canonical_path, configmap_path, schema_path, gateway_dir = sys.argv[1:5]

try:
    import yaml
except Exception as e:  # pragma: no cover
    print(f"FATAL: PyYAML is required ({e}).", file=sys.stderr)
    sys.exit(2)


def first_label(host: str) -> str:
    return host.split(".", 1)[0]


def first_segment(path: str) -> str:
    # "/well-known/**" -> ".well-known"? No: strip leading slash, take up to next
    # slash/glob; the literal segment as routed.
    p = path.strip()
    p = p.lstrip("/")
    seg = re.split(r"[/*]", p, maxsplit=1)[0]
    return seg


# Path/host first-labels that are NOT dedicated app prefixes and must be ignored:
#   - apex host (snapdragon) and wildcards (*) are not reserved labels
#   - "/" (front page) and "/**" (catch-all) yield empty segments
#   - DEEP sub-paths that are NOT a first segment of a top-level route. We only
#     ever take the FIRST segment, so e.g. /api/v1/pleroma/... contributes "api".
IGNORE = {"", "snapdragon", "*"}

# Normalization: a few deployed segments carry punctuation the reserved list
# spells without it (the reserved list is the username/label form). Map them.
NORMALIZE = {
    ".well-known": "well-known",  # /.well-known/** route -> reserved 'well-known'
}


def normalize(label: str) -> str:
    return NORMALIZE.get(label, label)


# ---- 1) canonical source ---------------------------------------------------
with open(canonical_path) as fh:
    canon_doc = yaml.safe_load(fh)
reserved = canon_doc.get("spec", {}).get("reserved", [])
if not isinstance(reserved, list) or not reserved:
    print(f"FATAL: {canonical_path} has no spec.reserved list", file=sys.stderr)
    sys.exit(2)
# duplicate guard
dupes = sorted({x for x in reserved if reserved.count(x) > 1})
if dupes:
    print(f"FAIL: canonical reserved list has DUPLICATES: {dupes}", file=sys.stderr)
    sys.exit(1)
reserved_set = set(reserved)

# ---- 2) configmap mirror must equal the canonical source -------------------
with open(configmap_path) as fh:
    cm_doc = yaml.safe_load(fh)
cm_raw = cm_doc.get("data", {}).get("reserved.json")
if cm_raw is None:
    print(f"FATAL: {configmap_path} has no data['reserved.json']", file=sys.stderr)
    sys.exit(2)
cm_set = set(json.loads(cm_raw))
if cm_set != reserved_set:
    only_canon = sorted(reserved_set - cm_set)
    only_cm = sorted(cm_set - reserved_set)
    print("FAIL: ConfigMap mirror DRIFTED from canonical source:", file=sys.stderr)
    if only_canon:
        print(f"  in canonical but NOT ConfigMap: {only_canon}", file=sys.stderr)
    if only_cm:
        print(f"  in ConfigMap but NOT canonical: {only_cm}", file=sys.stderr)
    print("  -> re-run scripts/sync-reserved-configmap.sh", file=sys.stderr)
    sys.exit(1)

# ---- 3) deployed route prefixes from the gateway apps ----------------------
deployed = {}  # label -> set(sources)


def add(label, source):
    label = normalize(label)
    if label in IGNORE:
        return
    deployed.setdefault(label, set()).add(source)


gateway_files = sorted(glob.glob(os.path.join(gateway_dir, "20-gateway-*.yaml")))
if not gateway_files:
    print(f"FATAL: no gateway apps matched {gateway_dir}/20-gateway-*.yaml", file=sys.stderr)
    sys.exit(2)

for gf in gateway_files:
    base = os.path.basename(gf)
    with open(gf) as fh:
        for app in yaml.safe_load_all(fh):
            if not app:
                continue
            helm = (((app.get("spec") or {}).get("source") or {}).get("helm") or {})
            values_raw = helm.get("values")
            if not values_raw:
                continue
            values = yaml.safe_load(values_raw) or {}
            ing = values.get("ingress") or {}
            # ingress host + extraHosts (reserved subdomains)
            if ing.get("host"):
                add(first_label(str(ing["host"])), f"{base}:ingress.host")
            for eh in (ing.get("extraHosts") or []):
                add(first_label(str(eh)), f"{base}:ingress.extraHosts")
            # routes: path first-segments + host predicates
            for r in (values.get("routes") or []):
                if r.get("path"):
                    add(first_segment(str(r["path"])), f"{base}:route[{r.get('id','?')}].path")
                if r.get("host"):
                    add(first_label(str(r["host"])), f"{base}:route[{r.get('id','?')}].host")

# ---- 4) route-access schema.sql url_pattern first-segments -----------------
with open(schema_path) as fh:
    sql = fh.read()
for m in re.finditer(r"'(/[^']*)'", sql):
    add(first_segment(m.group(1)), "schema.sql:url_pattern")

# ---- 5) the assertion: reserved ⊇ deployed ---------------------------------
missing = sorted(set(deployed) - reserved_set)

print("== reserved-prefix route-consistency check ==")
print(f"canonical reserved labels : {len(reserved_set)}")
print(f"ConfigMap mirror          : OK (matches canonical)")
print(f"deployed route prefixes   : {len(deployed)}")
print("deployed prefixes observed :")
for label in sorted(deployed):
    mark = "OK " if label in reserved_set else "MISSING"
    src = ", ".join(sorted(deployed[label]))
    print(f"  [{mark}] {label:<14} <- {src}")

if missing:
    print()
    print("FAIL: these DEPLOYED route prefixes are NOT in the canonical reserved set:", file=sys.stderr)
    for label in missing:
        print(f"  - {label}  (sources: {', '.join(sorted(deployed[label]))})", file=sys.stderr)
    print(file=sys.stderr)
    print("Add each to specs/cluster/reserved-prefixes.yaml (and the app-repo", file=sys.stderr)
    print("ReservedNames copies), re-run scripts/sync-reserved-configmap.sh, retry.", file=sys.stderr)
    sys.exit(1)

print()
print(f"PASS: canonical reserved set covers all {len(deployed)} deployed route prefixes.")
sys.exit(0)
PY

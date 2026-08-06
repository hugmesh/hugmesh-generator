#!/usr/bin/env bash
# test-no-duplicate-env.sh — no container may declare the same env name twice.
#
# WHY THIS EXISTS. A lane adding a batch of explicit env overrides re-declared
# ROUTE_MIRROR_CASSANDRA in a container that already set it 125 lines earlier,
# under a long comment explaining precisely why that value matters. Kubernetes
# does not reject a duplicate env name — it silently takes the LAST one. The two
# values happened to agree, so nothing broke; but the next person to correct the
# documented entry would have changed nothing at all, and no test anywhere looked
# at env-name uniqueness. That is a trap laid for a future edit, and it is
# cheap to make impossible.
#
# Checks every container (and initContainer) of every workload in specs/cluster,
# whether the entry is written in block form or inline flow form. Offline:
# python3 + PyYAML only.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
ROOT="${ENV_DUP_ROOT:-${REPO}/specs/cluster}"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

# Tooling absent is a hard failure, never a skip: a guard that skips in CI is a
# guard that never guards, and this repo has shipped several of those.
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required (refusing to skip)" >&2; exit 1; }
python3 -c 'import yaml' >/dev/null 2>&1 || { echo "FATAL: PyYAML required (refusing to skip)" >&2; exit 1; }

echo "== duplicate env names: ${ROOT} =="

scan() { # <root> -> prints "file | workload | container | NAME xN" per duplicate
  ENV_ROOT="$1" python3 - <<'PY'
import os, sys, pathlib, yaml
root = pathlib.Path(os.environ["ENV_ROOT"])
found = []
scanned = 0
for path in sorted(root.rglob("*.yaml")):
    try:
        docs = list(yaml.safe_load_all(path.read_text(encoding="utf-8")))
    except Exception:
        continue                      # helm templates etc. are not our business
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        spec = (doc.get("spec") or {}).get("template", {}).get("spec") if isinstance(doc.get("spec"), dict) else None
        if not isinstance(spec, dict):
            continue
        name = (doc.get("metadata") or {}).get("name", "?")
        for key in ("initContainers", "containers"):
            for c in (spec.get(key) or []):
                if not isinstance(c, dict):
                    continue
                env = c.get("env")
                if not isinstance(env, list):
                    continue
                scanned += 1
                seen = {}
                for e in env:
                    if isinstance(e, dict) and "name" in e:
                        seen[e["name"]] = seen.get(e["name"], 0) + 1
                for n, count in seen.items():
                    if count > 1:
                        found.append(f"{path.relative_to(root)} | {name} | {c.get('name','?')} | {n} x{count}")
for f in found:
    print(f"    {f}")
print(f"__SCANNED__ {scanned}", file=sys.stderr)
sys.exit(1 if found else 0)
PY
}

if scan "${ROOT}" 2>/tmp/envdup.err; then
  ok "no container declares the same env name twice ($(sed -n 's/__SCANNED__ //p' /tmp/envdup.err) container(s) with env scanned)"
else
  bad "duplicate env name(s) above — kubernetes silently keeps the LAST, so the documented entry is dead"
fi

# A scan that finds no containers would pass vacuously.
n="$(sed -n 's/__SCANNED__ //p' /tmp/envdup.err)"
if [ "${n:-0}" -ge 20 ]; then
  ok "vacuity: the scan really walked the tree (${n} containers with env)"
else
  bad "vacuity: only ${n:-0} container(s) with env found — the scan is not reaching the manifests"
fi

echo "-- negative control --"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/x"
cat > "${T}/x/dup.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: { name: probe }
spec:
  template:
    spec:
      containers:
        - name: app
          env:
            - name: DUPED
              value: "first"
            - { name: DUPED, value: "second" }
YAML
if scan "${T}" >/dev/null 2>&1; then
  bad "negative control: a duplicate env (block + inline form) was NOT caught"
else
  ok "negative control: duplicate env across block and inline forms is caught"
fi

echo
echo "== duplicate env names: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]

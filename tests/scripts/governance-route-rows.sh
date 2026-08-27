#!/usr/bin/env bash
# governance-route-rows.sh — the CLI view of the governance surface.
#
# Prints, as JSON, every gateway_route_access row in the shipped seed
# (specs/cluster/manifests/route-access/initdb/20-schema.sql) that governs a
# GOVERNANCE prefix — the admin, mod, superadmin, fleet, games-admin and
# per-service admin consoles — grouped by (gateway, url_pattern).
#
# WHY IT EXISTS. Two consumers, one parse:
#   1. tests/e2e/features/rbac/governance-evidence-environments.feature drives it
#      as the CLI-INTERFACE leg of this domain, so "the governance contract is
#      readable from a terminal" is an executed claim with a real transcript
#      artefact rather than a browser screenshot of the same thing.
#   2. tests/scripts/test-e2e-governance-function-matrix.sh uses it as an
#      INDEPENDENT reading of the seed: the TypeScript catalogue's row parse and
#      this one are written separately and must agree on the row count, so a
#      parser that silently stops matching cannot take the whole matrix quiet.
#
# COMMENT STRIPPING IS LOAD-BEARING. 20-schema.sql documents almost every row in
# a `--` comment that repeats the pattern text, so a naive `grep -c '/bff/mod/**'`
# returns 7 where there are 2 real rows. This reads TUPLES only.
#
# OUTPUT IS ONE LINE OF JSON. The Gherkin step that consumes it parses the LAST
# stdout line; pipe through `jq .` to read it.
#
# Starts nothing, needs no root, and reads exactly one file.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SEED="${REPO}/specs/cluster/manifests/route-access/initdb/20-schema.sql"

if [ ! -f "${SEED}" ]; then
  echo "governance-route-rows: the route-access seed is missing: ${SEED}" >&2
  echo "Nothing was read, so nothing is reported. Exiting 2 rather than printing {}." >&2
  exit 2
fi

command -v python3 >/dev/null 2>&1 || {
  echo "governance-route-rows: python3 is required to parse the seed and is absent." >&2
  echo "This tool read NOTHING. Exiting 2 rather than 0." >&2
  exit 2
}

python3 - "${SEED}" <<'PY'
import json, re, sys

seed = sys.argv[1]
text = open(seed, encoding='utf-8').read()

# One INSERT tuple: ('gateway', '/pattern', 'ROLE', true|false). Anchored on the
# gateway name, which is the only token in this file shaped like this.
ROW = re.compile(r"\(\s*'(hugmesh-[a-z0-9-]*gateway)'\s*,\s*'(/[^']*)'\s*,\s*'([A-Z_]+)'\s*,\s*(true|false)\s*\)")

# The prefixes that make a row a GOVERNANCE row. Deliberately explicit: a
# substring test like "admin" would sweep in /api/v1/pleroma/admin/** (wanted)
# AND /bff/admin/... (wanted) AND nothing else by accident, but it would also
# hide the day someone adds a governance surface under a new prefix — so a new
# prefix has to be added here on purpose.
GOV_PREFIXES = (
    '/admin', '/bff/admin', '/mod', '/bff/mod',
    '/bff/superadmin', '/superadmin', '/api/admin',
    '/games/admin', '/games/api/admin',
    '/api/v1/pleroma/admin', '/api/pleroma/admin', '/pleroma/admin',
    '/bff/forum/admin', '/bff/forum/moderation', '/api/forum/admin',
    '/bff/wiki/admin', '/bff/owncast/admin', '/bff/image-builds',
)

rows = [m.groups() for m in ROW.finditer(text)]
if not rows:
    print(json.dumps({"error": "parsed ZERO route rows — the INSERT grammar changed"}))
    sys.exit(3)

grouped = {}
for gw, pat, role, allow in rows:
    if not any(pat == p or pat.startswith(p + '/') for p in GOV_PREFIXES):
        continue
    key = (gw, pat)
    e = grouped.setdefault(key, {"gateway": gw, "pattern": pat, "allow": [], "deny": []})
    (e["allow"] if allow == 'true' else e["deny"]).append(role)

out = {
    "seed": "specs/cluster/manifests/route-access/initdb/20-schema.sql",
    "totalRows": len(rows),
    "governanceRows": sum(len(e["allow"]) + len(e["deny"]) for e in grouped.values()),
    "governancePatterns": len(grouped),
    "patterns": [
        {"gateway": e["gateway"], "pattern": e["pattern"],
         "allow": sorted(set(e["allow"])), "deny": sorted(set(e["deny"]))}
        for e in sorted(grouped.values(), key=lambda x: (x["gateway"], x["pattern"]))
    ],
}
# ONE LINE, deliberately. tests/e2e/steps/common.steps.ts's shared
# "the command output is valid JSON" step parses the LAST stdout line, so a
# pretty-printed object fails as `}`. Compact output keeps the shared step usable
# and keeps this tool pipeable into jq, which is what an operator does with it.
print(json.dumps(out, sort_keys=True))
PY

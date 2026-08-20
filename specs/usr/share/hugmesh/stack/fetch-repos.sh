#!/usr/bin/env bash
# fetch-repos.sh — clone (or update) the hugmesh org repos next to this
# script so hugmesh-stack can build the whole stack from source. Private repos
# need auth (gh auth login, or an SSH key); public ones clone anonymously.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORG="${HUGMESH_ORG:-hugmesh}"
BASE="${HUGMESH_GIT_BASE:-https://github.com/${ORG}}"

# The core stack repos (extend freely). hugmesh-generator carries the cluster +
# compose manifests; the rest are the services/UIs.
REPOS=(
    hugmesh-generator hugmesh-commons hugmesh-parent
    admin-bff user-bff mod-bff forum-bff owncast-bff tube-bff wiki-bff
    auth-core federation-api
    hugmesh.net login-ui admin-ui mod-ui matrix-ui owncast-ui tube-ui
)

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    CLONE(){ gh repo clone "${ORG}/$1" "${HERE}/$1" -- -q 2>/dev/null; }
else
    CLONE(){ git clone -q "${BASE}/$1.git" "${HERE}/$1" 2>/dev/null; }
fi

for r in "${REPOS[@]}"; do
    if [ -d "${HERE}/${r}/.git" ]; then
        echo "  update ${r}"; git -C "${HERE}/${r}" pull -q --ff-only 2>/dev/null || echo "    (skip: ${r})"
    else
        echo "  clone  ${r}"; CLONE "${r}" || echo "    (could not fetch ${r} — private? run 'gh auth login')"
    fi
done
echo "Done. Now: ./hugmesh-stack up   (or  mesh-up  to join the tailnet as a node)"

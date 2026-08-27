#!/usr/bin/env bash
# fetch-repos.sh — clone (or update) the hugmesh org repos next to this
# script so hugmesh-stack can build the whole stack from source. Private repos
# need auth (gh auth login, or an SSH key); public ones clone anonymously.
#
# NAMES ARE THE REAL GITHUB REPO NAMES, VERBATIM. This list once said
# `admin-bff`, `auth-core`, `login-ui` and `hugmesh.net` — none of which exists
# under github.com/hugmesh (the repos are hugmesh-admin-bff-api,
# hugmesh-auth-core, hugmesh-login-ui and hugmesh-host-shell). Every clone
# failed, the failure was swallowed by a `2>/dev/null || echo "(could not
# fetch … — private?)"`, and the script still printed "Done." and exited 0 —
# so a seeded box blamed auth for a list that could never resolve. Two things
# now stop that from coming back:
#   * tests/scripts/test-stack-fetch-repos.sh pins this list against the org's
#     real repo names (offline) and the compose build contexts that consume the
#     clones; an entry naming a repo the org does not have is a red gate, not a
#     runtime shrug. (An ORG-SIDE rename of a listed repo is only visible to
#     `LIVE=1 bash tests/scripts/test-stack-fetch-repos.sh` — re-pin after one.)
#   * a repo that cannot be fetched is REPORTED and the script exits non-zero
#     (see the tail), with the base URL it tried, so "the name is wrong" and
#     "you are not logged in" are distinguishable on the console.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORG="${HUGMESH_ORG:-hugmesh}"
BASE="${HUGMESH_GIT_BASE:-https://github.com/${ORG}}"

# The core stack repos (extend freely — with the repo's REAL name). hugmesh-generator
# carries the cluster + compose manifests; build-config/parent/commons/auth-core
# are the Maven chain every Spring service resolves (in that dependency order);
# the rest are the services/UIs. docker-compose.yml's build contexts are
# `./<one of these names>`, so the two files must agree exactly.
REPOS=(
    hugmesh-generator
    hugmesh-build-config hugmesh-parent hugmesh-commons hugmesh-auth-core
    hugmesh-gateway hugmesh-federation-api
    hugmesh-admin-bff-api hugmesh-user-bff-api hugmesh-mod-bff-api
    hugmesh-forum-bff-api hugmesh-owncast-bff-api hugmesh-tube-bff-api hugmesh-wiki-bff-api
    hugmesh-host-shell hugmesh-login-ui hugmesh-admin-ui hugmesh-mod-ui
    hugmesh-matrix-ui hugmesh-owncast-ui hugmesh-tube-ui
)

# Never let git sit on an interactive "Username for https://github.com:" prompt
# inside a first-boot hook or a Studio subprocess — fail, and say so below.
export GIT_TERMINAL_PROMPT=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    CLONE(){ gh repo clone "${ORG}/$1" "${HERE}/$1" -- -q; }
else
    CLONE(){ git clone -q "${BASE}/$1.git" "${HERE}/$1"; }
fi

failed=()
for r in "${REPOS[@]}"; do
    if [ -d "${HERE}/${r}/.git" ]; then
        echo "  update ${r}"
        git -C "${HERE}/${r}" pull -q --ff-only || { echo "    (skip: ${r} — not fast-forwardable, left as is)"; }
    else
        echo "  clone  ${r}"
        CLONE "${r}" || failed+=("${r}")
    fi
done

if [ "${#failed[@]}" -gt 0 ]; then
    echo "ERROR: could not fetch ${#failed[@]} of ${#REPOS[@]} repo(s): ${failed[*]}" >&2
    echo "       base=${BASE}" >&2
    echo "       If it is 'repository not found', the NAME is wrong — compare against" >&2
    echo "       'gh repo list ${ORG} --limit 200'. If it is an auth error, run 'gh auth login'." >&2
    exit 1
fi
echo "Done. Now: ./hugmesh-stack up   (or  mesh-up  to join the tailnet as a node)"

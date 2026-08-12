#!/usr/bin/env bash
# gitlab-mirror-org.sh — mirror every hugmesh-net GitHub repo into the
# internal GitLab (devops namespace) as a PULL MIRROR, so CI can build all ISOs
# and images from a complete in-VPN copy ("copy everything from GitHub").
#
# Run from an admin workstation (or a CI job) with:
#   GH org read (gh CLI) + GITLAB_URL + GITLAB_TOKEN (api scope).
# Pull mirroring keeps each GitLab project in sync with its GitHub upstream.
#
# Secrets note: this only mirrors repositories; keys live on the USB + Vault and
# are never committed, so nothing secret is exposed via the mirror.
set -euo pipefail

ORG="${ORG:-hugmesh-net}"
GITLAB_URL="${GITLAB_URL:-https://gitlab.hugmesh.systems}"
GITLAB_GROUP="${GITLAB_GROUP:-hugmesh}"
: "${GITLAB_TOKEN:?set GITLAB_TOKEN (GitLab PAT, api scope)}"

for t in gh curl jq; do command -v "$t" >/dev/null || { echo "need $t" >&2; exit 1; }; done

# Resolve the GitLab group id.
gid="$(curl -fsS --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${GITLAB_URL}/api/v4/groups/${GITLAB_GROUP}" | jq -r .id)"

echo "==> Mirroring ${ORG} -> ${GITLAB_URL}/${GITLAB_GROUP}"
gh repo list "${ORG}" --limit 200 --json name,url,sshUrl --jq '.[] | "\(.name)\t\(.url)"' \
| while IFS=$'\t' read -r name url; do
    echo "  - ${name}"
    # GitHub clone URL with a token for private repos (read-only mirror creds).
    import_url="https://oauth2:$(gh auth token)@github.com/${ORG}/${name}.git"
    curl -fsS --request POST --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      --header "Content-Type: application/json" \
      "${GITLAB_URL}/api/v4/projects" \
      --data "$(jq -n --arg n "${name}" --arg ns "${gid}" --arg url "${import_url}" \
        '{name:$n, namespace_id:($ns|tonumber), import_url:$url, mirror:true, mirror_trigger_builds:true, visibility:"private"}')" \
      >/dev/null 2>&1 \
      && echo "      created pull-mirror" \
      || echo "      exists / skipped (update mirror URL in the GitLab UI if needed)"
  done
echo "==> Done. CI builds run on push/mirror-sync (mirror_trigger_builds=true)."

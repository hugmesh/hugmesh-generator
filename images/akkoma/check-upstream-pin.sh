#!/usr/bin/env bash
# Checks that the upstream Akkoma tag images/akkoma/Dockerfile names still points at
# the commit it builds (AKKOMA_COMMIT), and that both build stages carry the same
# pins. Run by akkoma-release.yml's version job and by akkoma-image-ci.yml. Needs git
# and network access to the upstream repository; fails closed when it cannot ask.
#
#   bash images/akkoma/check-upstream-pin.sh [Dockerfile]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dockerfile="${1:-$here/Dockerfile}"

# arg NAME: every default the Dockerfile gives ARG NAME, one per line, deduplicated.
arg() { sed -n "s/^ARG $1=//p" "$dockerfile" | sort -u; }

for name in AKKOMA_GIT_URL AKKOMA_VERSION AKKOMA_COMMIT; do
  n="$(arg "$name" | grep -c . || true)"
  if [ "$n" != 1 ]; then
    echo "::error::$dockerfile gives ARG $name $n different defaults; every stage must carry the same one" >&2
    exit 1
  fi
done
url="$(arg AKKOMA_GIT_URL)"
version="$(arg AKKOMA_VERSION)"
commit="$(arg AKKOMA_COMMIT)"
if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::AKKOMA_COMMIT '$commit' is not a full 40-hex commit id" >&2
  exit 1
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::AKKOMA_VERSION '$version' is not MAJOR.MINOR.PATCH" >&2
  exit 1
fi

rc=0
listing="$(git ls-remote "$url" "refs/tags/v$version" "refs/tags/v$version^{}")" || rc=$?
if [ "$rc" != 0 ]; then
  echo "::error::could not list tag v$version at $url (git ls-remote exit $rc); refusing to guess" >&2
  exit 1
fi
# An annotated tag lists its own object and a peeled ^{} line; the peeled one is the
# commit. A lightweight tag lists only the commit.
peeled="$(printf '%s\n' "$listing" | awk -v r="refs/tags/v$version^{}" '$2 == r {print $1}')"
plain="$(printf '%s\n' "$listing" | awk -v r="refs/tags/v$version" '$2 == r {print $1}')"
tagged="${peeled:-$plain}"
if [ -z "$tagged" ]; then
  echo "::error::$url has no tag v$version" >&2
  exit 1
fi
if [ "$tagged" != "$commit" ]; then
  echo "::error::upstream tag v$version is now $tagged, not the pinned AKKOMA_COMMIT $commit. Upstream moved its tag: find out why before building anything from it." >&2
  exit 1
fi
echo "upstream v$version -> $commit (pinned commit, $url)"

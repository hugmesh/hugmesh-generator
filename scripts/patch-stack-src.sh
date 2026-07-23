#!/usr/bin/env bash
# patch-stack-src.sh — the COMMITTED post-clone patch pass over ./.stack-src.
#
# scripts/clone-all-repos.sh calls this after every clone/update run. It is the
# ONE general mechanism for the small source tweaks the LOCAL docker-compose
# stack needs on the cloned service trees — never hand-edit a sibling checkout;
# add an idempotent patch function here instead.
#
# Ground rules for every patch:
#   * IDEMPOTENT — detect "already applied" and skip (the clone script
#     `reset --hard`s each checkout on update, so patches re-apply every run).
#   * CRLF-TOLERANT — several upstream files carry \r\n line endings (e.g.
#     hugmesh.systems' Dockerfile); match/anchor in a way that survives a
#     trailing \r, never with fragile whole-line sed equality.
#   * SCOPED — key off a positive marker in the target file, not off repo
#     names, so upstream fixes make a patch a natural no-op.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
STACK_SRC="${1:-${STACK_SRC:-${REPO_ROOT}/.stack-src}}"

patched=0 scanned=0

# ── patch: let the plain-HTTP local m2 registry through Maven 3.9's
#           maven-default-http-blocker ──────────────────────────────────────────
# The Java BFF/federation repos pin Maven 3.9.x via their maven wrapper; 3.9's
# bundled installation settings ship a `maven-default-http-blocker` mirror that
# blocks EVERY external http:// repository — including our local registry
# container (tests/stack/m2-bootstrap.sh), which is plain HTTP by design (a
# throwaway static server on the docker bridge). The committed settings.xml
# files (`./mvnw -B -s settings.xml package`) contain no <mirrors> override, so
# user settings never shadow the blocker. Fix: inject a mirror with the SAME id
# into the repo's settings.xml — same-id user mirrors take precedence over the
# installation one — re-pointed at a mirrorOf selector that matches nothing.
# Marker-scoped: only settings.xml files that resolve via ${env.CI_API_V4_URL}
# (the gitlab-maven consumers) and don't already mention the blocker id.
unblock_http_registry() { # <repo-checkout-dir>
  local f="$1/settings.xml"
  [ -f "${f}" ] || return 0
  grep -q 'CI_API_V4_URL' "${f}" || return 0            # not a gitlab-maven consumer
  grep -q 'maven-default-http-blocker' "${f}" && return 0  # already patched/fixed
  awk '
    /<\/settings>/ && !done {
      print "  <!-- injected by scripts/patch-stack-src.sh (local stack cold build):"
      print "       neutralize Maven 3.9'"'"'s external-http blocker so the plain-HTTP"
      print "       local m2 registry container (tests/stack/m2-bootstrap.sh) resolves."
      print "       Same-id user mirrors override the installation-settings one. -->"
      print "  <mirrors>"
      print "    <mirror>"
      print "      <id>maven-default-http-blocker</id>"
      print "      <mirrorOf>__matches-no-repository__</mirrorOf>"
      print "      <url>http://0.0.0.0/</url>"
      print "    </mirror>"
      print "  </mirrors>"
      done=1
    }
    { print }
  ' "${f}" > "${f}.patch-tmp" && mv "${f}.patch-tmp" "${f}"
  echo "  ~ $(basename "$1")/settings.xml: http-blocker override injected"
  patched=$((patched+1))
}

if [ ! -d "${STACK_SRC}" ]; then
  echo "==> patch-stack-src: ${STACK_SRC} does not exist (nothing to patch)"
  exit 0
fi

for dir in "${STACK_SRC}"/*/; do
  [ -d "${dir}" ] || continue
  scanned=$((scanned+1))
  unblock_http_registry "${dir%/}"
done
echo "==> patch-stack-src: ${scanned} checkout(s) scanned, ${patched} patched"

#!/usr/bin/env bash
# test-m2-bootstrap.sh — guards the private-maven bootstrap that a COLD local-mesh
# bring-up depends on, and the shell bug class that silently broke it.
#
# THE BUG: build_one()'s `docker run` carried its explanatory comment BETWEEN the
# image argument and the `mvn` command, inside the backslash continuation:
#
#     docker run --rm \
#       -v … -v … -w /work \
#       "${MAVEN_IMAGE}" \
#       # -Dhugmesh.analysis.skip=true is the parent POM's OWN switch …
#       mvn -B -ntp -s /usr/share/maven/ref/settings-docker.xml install …
#
# A `\` continuation joins the NEXT line, that line began with `#`, so bash read
# the whole thing as `docker run … "${MAVEN_IMAGE}"   # comment…` — the container
# launched with NO mvn command (the image's default CMD), the logical line ended
# at the comment, and the `mvn … install` lines below ran as a SEPARATE command
# ON THE HOST against a settings path that only exists inside the container.
# Reproduced verbatim with stub docker/mvn functions:
#     DOCKER GOT: --rm -v cache:/ref maven:image
#     MVN RAN ON HOST with: -B install -DskipTests
# So build_one could never populate the cache, `make stack-m2-bootstrap` emitted
# no artifacts, and every COLD `make stack-up` then failed at the first
# private-maven consumer. `bash -n` does NOT catch this — it is valid bash that
# means something else.
#
# Section 2 is therefore a REPO-WIDE lint for that class, not just this one site.
#
# Pure static + stub-harness checks: no docker, no network, no maven, no root.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BOOT="${HERE}/m2-bootstrap.sh"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== m2-bootstrap (cold local-mesh prerequisite) =="

echo "-- 1) build_one really runs maven INSIDE the container --"
[ -f "${BOOT}" ] && ok "m2-bootstrap.sh present" || { bad "m2-bootstrap.sh missing"; echo; echo "== ${P} passed, $((F+1)) failed =="; exit 1; }
bash -n "${BOOT}" && ok "m2-bootstrap.sh parses" || bad "m2-bootstrap.sh does not parse"

# Extract build_one's body and assert the docker invocation and the mvn command
# are ONE logical command. Joining the continuations is the honest way to ask
# "what does bash actually execute here?" rather than eyeballing the source.
BODY="$(awk '/^build_one\(\)/{f=1} f{print} f&&/^}/{exit}' "${BOOT}")"
[ -n "${BODY}" ] && ok "found build_one()" || bad "build_one() not found"
# Collapse backslash-continuations exactly as bash does, then look at the docker line.
JOINED="$(printf '%s\n' "${BODY}" | sed -e :a -e '/\\$/N; s/\\\n//; ta')"
DOCKER_LINE="$(printf '%s\n' "${JOINED}" | grep -E '^\s*docker run' | head -1)"
[ -n "${DOCKER_LINE}" ] && ok "build_one issues a docker run" || bad "no docker run in build_one"
case "${DOCKER_LINE}" in
  *mvn*) ok "the joined docker line CARRIES the mvn command (runs in the container)" ;;
  *)     bad "the joined docker line has NO mvn — maven would run on the HOST: ${DOCKER_LINE}" ;;
esac
# The settings file lives inside the container image mount; if mvn ever escapes to
# the host this path is the tell, so pin that it travels WITH the docker command.
case "${DOCKER_LINE}" in
  *"-s /usr/share/maven/ref/settings-docker.xml"*) ok "container settings.xml is on the docker command line" ;;
  *) bad "the in-container settings.xml path is not part of the docker command" ;;
esac
# A stray host-level mvn call in this script would mean the split reappeared.
if printf '%s\n' "${JOINED}" | grep -qE '^\s*mvn '; then
  bad "a bare 'mvn' runs at the top level of build_one — that executes on the HOST"
else
  ok "no host-level mvn invocation"
fi

echo "-- 2) repo-wide lint: no comment inside a backslash continuation --"
# A line of CODE ending in '\' followed by a comment line: the comment swallows
# the rest of the logical line and everything after it becomes separate commands.
# (A '\' inside a comment block is NOT a continuation — usage/help text is full of
# them — so only non-comment continuation lines count.)
HITS="$(cd "${REPO}" && for f in $(git ls-files '*.sh' 2>/dev/null); do
          awk -v F="$f" '
            { if (prev==1 && $0 ~ /^[[:space:]]*#/) print F":"NR": " $0
              prev = ($0 ~ /\\$/ && $0 !~ /^[[:space:]]*#/) ? 1 : 0 }' "$f"
        done 2>/dev/null)"
if [ -z "${HITS}" ]; then
  ok "no shell script hides a comment inside a line continuation"
else
  bad "comment(s) inside a backslash continuation — the command is silently truncated:"
  printf '%s\n' "${HITS}" | sed 's/^/         /'
fi

echo "-- 2b) PIN drift: every private version a sibling pom requests must be served --"
# The pins are point-in-time SHAs of moving repos, so they rot: on 2026-07-29 both
# BFFs had bumped to auth-core 2.4.1 upstream while the pin still said 2.4.0, and
# the operator's cold `make stack-up` died 25 minutes in at user-bff with
#   Could not find artifact systems.hugmesh:hugmesh-auth-core:jar:2.4.1 in gitlab-maven
# This guard cross-checks the PINS array against what the CLONED sibling poms
# actually request, so the drift fails HERE (and in CI once .stack-src exists)
# instead of mid-bring-up. Literal <version> elements only — property refs like
# ${hugmesh-commons.version} resolve to a literal elsewhere in the same pom, and
# python walks the real XML so comment blocks between artifactId and version
# (admin-bff's style) cannot hide a consumer the way they hide from grep.
# STACK_SRC honored like every other stack tool (Makefile, m2-bootstrap.sh,
# kind-load-images.sh) — a checkout that builds from a shared/external
# .stack-src would otherwise SKIP this leg forever. That silent SKIP is how the
# 2.4.1 -> 2.4.2 auth-core drift shipped: CI has no .stack-src, so the guard
# stayed green while every cold build was broken.
SRC="${STACK_SRC:-${REPO}/.stack-src}"
if [ ! -d "${SRC}" ]; then
  echo "  SKIP .stack-src not populated (run 'make stack-clone') — pin-drift not checked"
else
  PINNED="$(sed -n 's/^  "\([a-z-]*\)|[0-9a-f]*|\([a-z-]*\)|\([0-9.]*\)|.*$/\2=\3/p' "${BOOT}")"
  [ -n "${PINNED}" ] && ok "parsed $(printf '%s\n' "${PINNED}" | wc -l) pins from the PINS array" \
                     || bad "could not parse the PINS array"
  DRIFT="$(PINNED="${PINNED}" SRC="${SRC}" python3 - <<'PYEOF'
import os, re, xml.etree.ElementTree as ET
pins = dict(l.split("=") for l in os.environ["PINNED"].split())
ns = {"m": "http://maven.apache.org/POM/4.0.0"}
def deps(root):
    for d in root.iter("{http://maven.apache.org/POM/4.0.0}dependency"):
        yield d
    p = root.find("m:parent", ns)
    if p is not None:
        yield p
for repo in sorted(os.listdir(os.environ["SRC"])):
    pom = os.path.join(os.environ["SRC"], repo, "pom.xml")
    if not os.path.isfile(pom):
        continue
    try:
        root = ET.parse(pom).getroot()
    except ET.ParseError as exc:
        print(f"{repo}: pom.xml unparsable ({exc})")
        continue
    props = {e.tag.split('}')[1]: (e.text or "").strip()
             for e in root.findall("m:properties/*", ns)}
    for d in deps(root):
        gid = d.findtext("m:groupId", "", ns).strip()
        aid = d.findtext("m:artifactId", "", ns).strip()
        ver = d.findtext("m:version", "", ns).strip()
        if gid != "systems.hugmesh" or aid not in pins or not ver:
            continue
        m = re.fullmatch(r"\$\{([^}]+)\}", ver)
        if m:
            if m.group(1) not in props:
                # Not local drift: an undefined-here property is inherited from
                # the <parent> chain — hugmesh-parent 2.8.0 defines
                # hugmesh-commons.version — and the parent itself IS a pin this
                # guard checks. Flagging these was the guard's own first false
                # positive (federation-api / tube-bff).
                continue
            ver = props[m.group(1)]
        if ver != pins[aid]:
            print(f"{repo}: wants {aid} {ver}, registry serves {pins[aid]}")
PYEOF
)"
  if [ -z "${DRIFT}" ]; then
    ok "every sibling-requested systems.hugmesh version matches its pin"
  else
    bad "PIN DRIFT — a cold stack build will die resolving these:"
    printf '%s\n' "${DRIFT}" | sed 's/^/         /'
  fi
fi

echo "-- 3) the truncation really does mean what we claim (harness) --"
# Not a guard on the repo — a proof of the semantics the comments above assert, so
# the reasoning is checkable rather than folklore.
#
# The probe is ASSEMBLED with printf rather than written as a literal heredoc,
# and that is load-bearing, not style: a heredoc fixture containing the broken
# pattern makes THIS tracked .sh file carry a code line ending in '\' followed
# by a comment line — exactly what section 2's repo-wide lint hunts — so the
# lint FLAGGED ITS OWN TEST and the suite shipped red on main (CI
# lint:m2-bootstrap failing from the day it landed; found while adding the
# pin-drift guard). ${BSL} keeps the backslash out of the tracked source while
# the generated probe.sh still ends its line with a real one.
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
BSL='\'
printf '%s\n' \
  'fake_docker() { echo "DOCKER:$*"; }' \
  'mvn() { echo "HOSTMVN:$*"; }' \
  "fake_docker --rm ${BSL}" \
  "  \"maven:image\" ${BSL}" \
  '  # comment inside the continuation' \
  '  mvn -B install' \
  > "${TMP}/probe.sh"
OUT="$(bash "${TMP}/probe.sh" 2>&1)"
case "${OUT}" in
  *"DOCKER:--rm maven:image"*) ok "docker really loses everything after the comment" ;;
  *) bad "harness did not reproduce the truncation: ${OUT}" ;;
esac
case "${OUT}" in
  *"HOSTMVN:-B install"*) ok "the mvn line really escapes to the host shell" ;;
  *) bad "harness did not reproduce the host escape: ${OUT}" ;;
esac

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

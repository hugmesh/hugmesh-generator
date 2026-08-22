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

# One cleanup list, one trap. Two sections below want a temp dir, and a second
# `trap … EXIT` REPLACES the first rather than adding to it — the earlier dir
# would just leak.
SCRATCH=""
scratch_dir(){ local d; d="$(mktemp -d "${TMPDIR:-/tmp}/${1:-m2-guard}.XXXXXX")"; SCRATCH="${SCRATCH} ${d}"; printf '%s' "${d}"; }
# shellcheck disable=SC2086
trap 'rm -rf ${SCRATCH}' EXIT

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
if printf '%s\n' "${JOINED}" | grep -E '^\s*mvn ' >/dev/null; then
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
#
# ── 3rd+ OCCURRENCE OF THE SAME DRIFT, SO THE SKIP IS NOW GONE ───────────────
# Honouring STACK_SRC was not enough. lint:m2-bootstrap sets no STACK_SRC and a
# CI checkout has no .stack-src, so this leg still printed SKIP and the job still
# exited 0 — the guard was "fixed" and remained exactly as blind as before. An
# input the runner can never supply is not an input; it is an off switch.
#
# Two changes:
#   1. NO SOURCE => FAILURE whenever this runs unattended ($CI set, or
#      REQUIRE_STACK_SRC=1). A human at a terminal can opt out explicitly with
#      M2_PIN_DRIFT_SKIP=1; nothing else may skip.
#   2. CI gets a real corpus of its own. Rather than a full `make stack-clone`
#      (minutes, whole working trees), fetch ONLY each consumer's root files:
#        git clone --depth 1 --filter=blob:none --sparse
#      `--sparse` checks out "only files in the toplevel directory" (git-clone(1))
#      and `--filter=blob:none` defers every other blob, so each consumer costs
#      one small fetch and pom.xml is exactly what lands. A server that does not
#      advertise the filter capability is NOT a failure — verified against git
#      2.54.0 with uploadpack.allowFilter=false, which prints
#        warning: filtering not recognized by server, ignoring
#      and still exits 0 with the toplevel checkout intact. So the filter is a
#      pure optimisation and cannot turn this job red on its own.
#      NOT raw.githubusercontent: these repos are private there (raw answers 404
#      without a token) and CI is GitLab, whose job token is already wired into
#      CI_REPOSITORY_URL — the same clone recipe lint:reserved-prefixes uses.
SRC="${STACK_SRC:-${REPO}/.stack-src}"
have_poms() { [ -d "$1" ] && [ -n "$(find "$1" -mindepth 2 -maxdepth 2 -name pom.xml -print -quit 2>/dev/null)" ]; }

if ! have_poms "${SRC}"; then
  # Derive the Maven consumers from the file the cold stack build itself uses,
  # so a new Java service cannot quietly escape the check: every ${STACK_SRC}
  # build context in compose.local.yaml whose repo is a *-api, the gateway or
  # actions (the repo's own words: "eight BFF/federation siblings" plus
  # hugmesh-gateway and hugmesh-actions, see scripts/patch-stack-src.sh).
  CONSUMERS="$(sed -n 's|.*context: \${STACK_SRC:-[^}]*}/\([a-z0-9-]*\).*|\1|p' \
                 "${REPO}/tests/stack/compose.local.yaml" 2>/dev/null \
               | grep -E '(-api|^hugmesh-gateway$|^hugmesh-actions$)' | sort -u)"
  # Where to fetch from, in falling order of explicitness:
  #   M2_PIN_GIT_BASE   this guard's own override (and what its proofs drive),
  #   CI_REPOSITORY_URL the org mirror + read-only job token, in a CI job,
  #   GIT_BASE          the same knob scripts/clone-all-repos.sh already honours.
  # No hard-coded default: a guard must not decide on its own to reach out to a
  # forge nobody named.
  GIT_BASE_M2="${M2_PIN_GIT_BASE:-}"
  if [ -z "${GIT_BASE_M2}" ] && [ -n "${CI_REPOSITORY_URL:-}" ]; then
    GIT_BASE_M2="$(dirname "${CI_REPOSITORY_URL}")"
  fi
  [ -n "${GIT_BASE_M2}" ] || GIT_BASE_M2="${GIT_BASE:-}"
  if [ -n "${CONSUMERS}" ] && [ -n "${GIT_BASE_M2}" ]; then
    FETCH_DIR="$(scratch_dir m2-pin-src)"
    FETCH_FAIL=""
    NOT_MAVEN=""
    echo "  .. fetching consumer pom.xml (sparse, blobless) from ${GIT_BASE_M2%%://*}://…"
    for c in ${CONSUMERS}; do
      if git clone --quiet --depth 1 --filter=blob:none --sparse \
           "${GIT_BASE_M2}/${c}.git" "${FETCH_DIR}/${c}" 2>/dev/null; then
        # A cloned consumer with no pom.xml is legitimately possible (the list is
        # derived from compose contexts by name pattern, and a *-api need not be
        # a Java service), so this is not a failure — but it MUST be visible.
        # Dropping it in silence is how the corpus quietly shrinks to nothing.
        if [ ! -f "${FETCH_DIR}/${c}/pom.xml" ]; then
          NOT_MAVEN="${NOT_MAVEN} ${c}"
          rm -rf "${FETCH_DIR}/${c}"
        fi
      else
        FETCH_FAIL="${FETCH_FAIL} ${c}"
      fi
    done
    if [ -n "${NOT_MAVEN}" ]; then
      echo "  .. cloned but carry no pom.xml, so NOT part of the drift corpus:${NOT_MAVEN}"
    fi
    if [ -n "${FETCH_FAIL}" ]; then
      bad "could not fetch consumer pom.xml for:${FETCH_FAIL} — pin drift CANNOT be checked (fail-closed; do not let this pass)"
    fi
    SRC="${FETCH_DIR}"
  fi
fi

if ! have_poms "${SRC}"; then
  if [ "${M2_PIN_DRIFT_SKIP:-}" = "1" ]; then
    echo "  SKIP pin-drift explicitly opted out (M2_PIN_DRIFT_SKIP=1)"
  elif [ -n "${CI:-}" ] || [ "${REQUIRE_STACK_SRC:-}" = "1" ]; then
    bad "no consumer pom.xml available (no .stack-src, no STACK_SRC, fetch unavailable) and this is an UNATTENDED run — the pin-drift leg must never silently pass here"
  else
    bad "no consumer pom.xml available — run 'make stack-clone', set STACK_SRC, set M2_PIN_GIT_BASE/GIT_BASE to fetch, or opt out with M2_PIN_DRIFT_SKIP=1"
  fi
else
  PINNED="$(sed -n 's/^  "\([a-z-]*\)|[0-9a-f]*|\([a-z-]*\)|\([0-9.]*\)|.*$/\2=\3/p' "${BOOT}")"
  [ -n "${PINNED}" ] && ok "parsed $(printf '%s\n' "${PINNED}" | wc -l) pins from the PINS array" \
                     || bad "could not parse the PINS array"
  # ── THE WALKER'S OUTPUT IS A PROTOCOL, NOT PROSE ────────────────────────────
  # Every line it prints is exactly one of
  #     DRIFT <repo>: wants <artifact> <v>, registry serves <v>
  #     UNREADABLE <path> :: <why>
  #     SEEN <n>                                    (exactly once, digits only)
  # and the shell below FAILS on anything else. That rule exists because the
  # previous revision filtered the walker's output with `sed -n 's/^DRIFT //p'`
  # while the walker still emitted a bare "<repo>: pom.xml unparsable (…)" — so a
  # truncated or corrupt consumer pom was DROPPED by the filter and read as a
  # clean green, where the revision before it (no filter, any output = drift)
  # would have surfaced it. Un-blinding the guard had made it blinder. A protocol
  # plus a catch-all is the structural fix: a signal the filter does not know
  # about can no longer be mistaken for silence.
  DRIFT_RAW="$(PINNED="${PINNED}" SRC="${SRC}" python3 - <<'PYEOF'
import os, re, sys, xml.etree.ElementTree as ET
NS = "http://maven.apache.org/POM/4.0.0"
pins = dict(l.split("=") for l in os.environ["PINNED"].split())
ns = {"m": NS}

def esc(s):
    """Repo names come from a directory listing — data from outside this script.
    A name containing a newline would otherwise let the CORPUS forge a line of
    the walker's own output protocol (a counterfeit `SEEN 9999`, say, which is
    precisely the anti-vacuity counter). Escaping makes every emitted record
    exactly one line."""
    return s.encode("unicode_escape").decode("ascii")

def deps(root):
    for d in root.iter("{%s}dependency" % NS):
        yield d
    p = root.find("m:parent", ns)
    if p is not None:
        yield p

seen = 0        # pinned coordinates actually RESOLVED — the anti-vacuity counter
src = os.environ["SRC"]
try:
    entries = sorted(os.listdir(src))
except OSError as exc:
    print("UNREADABLE %s :: cannot list the consumer corpus: %s: %s"
          % (esc(src), type(exc).__name__, exc))
    print("SEEN 0")
    sys.exit(0)
for repo in entries:
    pom = os.path.join(src, repo, "pom.xml")
    if not os.path.isfile(pom):
        continue
    try:
        root = ET.parse(pom).getroot()
    except Exception as exc:
        # ANY failure to read this pom — a truncated or corrupt document
        # (ParseError), a permission/I-O error (OSError), an undecodable byte
        # stream. It means the drift check COULD NOT BE PERFORMED on this
        # consumer, which is a failure and not a pass: the whole point of the leg
        # is that a cold build resolves these coordinates, and a pom we cannot
        # read is a pom whose coordinates we do not know.
        print("UNREADABLE %s/pom.xml :: %s: %s" % (esc(repo), type(exc).__name__, exc))
        continue
    if root.tag != "{%s}project" % NS:
        # Parses, but not as the document this walk queries. Every findtext()
        # below uses the POM 4.0.0 namespace, so a namespace-less or wrong-root
        # file yields "" for every coordinate and contributes silently to
        # neither `seen` nor DRIFT — a per-file vacuous green the corpus-level
        # anti-vacuity counter cannot see, because the other consumers still
        # push `seen` above zero.
        print("UNREADABLE %s/pom.xml :: root element is <%s>, not the POM 4.0.0 "
              "<project> this walk queries — every coordinate lookup would "
              "silently return nothing" % (esc(repo), esc(root.tag)))
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
        seen += 1
        if ver != pins[aid]:
            print("DRIFT %s: wants %s %s, registry serves %s"
                  % (esc(repo), aid, ver, pins[aid]))
print("SEEN %d" % seen)
PYEOF
)"; PYRC=$?

  # The walker's own exit status. `VAR="$(cmd)"` keeps it, and throwing it away
  # is the same defect one level up: an interpreter that died mid-walk prints
  # nothing more, and "no DRIFT lines" would read as "no drift".
  if [ "${PYRC}" -ne 0 ]; then
    bad "the pin-drift walker exited ${PYRC} — the walk did not complete, so its silence means nothing"
  fi

  # ── DECODE THE PROTOCOL, AND REFUSE ANYTHING OUTSIDE IT ─────────────────────
  SEEN_LINES="$(printf '%s\n' "${DRIFT_RAW}" | sed -n 's/^SEEN \([0-9][0-9]*\)$/\1/p')"
  SEEN_N="$(printf '%s\n' "${SEEN_LINES}" | grep -c '[0-9]')"
  SEEN="$(printf '%s\n' "${SEEN_LINES}" | head -1)"
  DRIFT="$(printf '%s\n' "${DRIFT_RAW}" | sed -n 's/^DRIFT //p')"
  UNREADABLE="$(printf '%s\n' "${DRIFT_RAW}" | sed -n 's/^UNREADABLE //p')"
  UNKNOWN="$(printf '%s\n' "${DRIFT_RAW}" \
             | grep -vE '^(DRIFT |UNREADABLE |SEEN [0-9]+$)' | grep -v '^[[:space:]]*$')"

  if [ -n "${UNKNOWN}" ]; then
    bad "the pin-drift walker emitted line(s) OUTSIDE its output protocol — a filter that drops them turns a signal into a green:"
    printf '%s\n' "${UNKNOWN}" | sed 's/^/         /'
  fi
  if [ "${SEEN_N}" -ne 1 ]; then
    bad "expected exactly one 'SEEN <n>' line from the walker, got ${SEEN_N} — the walk did not finish, or something forged one"
    SEEN=0
  fi

  # AN UNREADABLE POM IS A FAILURE, NOT A PASS. The check it exists to perform
  # could not be performed on that file; reporting that as "every version
  # matches" is the lie this guard was written to stop telling.
  if [ -n "${UNREADABLE}" ]; then
    bad "consumer pom.xml could NOT be read — the pin-drift check was not performed for:"
    printf '%s\n' "${UNREADABLE}" | sed 's/^/         /'
  else
    ok "every consumer pom.xml in ${SRC} parsed as a POM 4.0.0 <project>"
  fi

  # ANTI-VACUITY. "No drift found" is the same output whether every consumer
  # agrees with the pins or the corpus contained no consumer at all. A sparse
  # fetch that produced empty checkouts, a STACK_SRC pointing somewhere stale, a
  # groupId rename — each turns this leg green while checking nothing, which is
  # the exact failure mode being repaired. Require the walk to have RESOLVED at
  # least one pinned coordinate before its silence is allowed to mean anything.
  if [ "${SEEN:-0}" -eq 0 ]; then
    bad "the pin-drift walk resolved ZERO systems.hugmesh coordinates in ${SRC} — nothing was actually checked (vacuous green)"
  else
    ok "pin-drift walk resolved ${SEEN} systems.hugmesh coordinate(s) across the consumer poms"
  fi
  if [ -z "${DRIFT}" ]; then
    ok "every sibling-requested systems.hugmesh version matches its pin"
  else
    bad "PIN DRIFT — a cold stack build will die resolving these:"
    printf '%s\n' "${DRIFT}" | sed 's/^/         /'
  fi
fi

# ── 2c) NEGATIVE CONTROLS FOR 2b ─────────────────────────────────────────────
# 2b's verdict is a SILENCE ("no DRIFT lines"), and silence is exactly what a
# broken corpus also produces. The previous revision of this leg proved that the
# hard way: it added `sed -n 's/^DRIFT //p'` to the output while the walker still
# emitted a bare "<repo>: pom.xml unparsable (…)", so the filter dropped the one
# line that said the check had not happened. Twelve consumers, one of them a
# truncated pom, read as a clean green.
#
# So 2b is re-run here against corpora built to be broken in five different ways,
# and every one must come back non-zero NAMING THE FILE. Each case is a distinct
# member of the class "the walker could not evaluate this pom" — one is an
# ET.ParseError, one is an OSError the old `except ET.ParseError` could not even
# catch, two parse perfectly and are simply not the document being queried, and
# one is a corpus-controlled string forging the walker's own output protocol.
# The corrupt consumer always sits among ELEVEN healthy ones, because a lone bad
# pom is caught by the anti-vacuity counter (seen == 0) by accident; hidden among
# working consumers, `seen` stays high and only a real signal finds it.
if [ -z "${M2_SELFTEST_CHILD:-}" ]; then
  echo "-- 2c) negative controls: a pom the walker cannot evaluate must FAIL --"
  NC="$(scratch_dir m2-negctl)"
  SELF_M2="${BASH_SOURCE[0]}"

  healthy_pom() { # healthy_pom <dir> <auth-core-version>
    mkdir -p "$1"
    cat > "$1/pom.xml" <<POM
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>systems.hugmesh</groupId>
    <artifactId>hugmesh-parent</artifactId>
    <version>2.8.0</version>
  </parent>
  <artifactId>consumer</artifactId>
  <properties><hugmesh-auth-core.version>$2</hugmesh-auth-core.version></properties>
  <dependencies>
    <dependency>
      <groupId>systems.hugmesh</groupId>
      <artifactId>hugmesh-auth-core</artifactId>
      <version>\${hugmesh-auth-core.version}</version>
    </dependency>
  </dependencies>
</project>
POM
  }

  base_corpus() { # base_corpus <dir> -> 11 healthy consumers agreeing with the pins
    local d="$1" n
    for n in admin-bff-api user-bff-api mod-bff-api federation-api tube-bff-api \
             forum-bff-api matrix-bff-api mesh-bff-api gateway actions api; do
      healthy_pom "${d}/hugmesh-${n}" "${AUTH_CORE_PIN}"
    done
  }

  # Take the auth-core pin from the PINS array itself, so these controls cannot
  # rot into failing for the boring reason that someone bumped a version.
  AUTH_CORE_PIN="$(printf '%s\n' "${PINNED:-}" | sed -n 's/^hugmesh-auth-core=//p' | head -1)"
  [ -n "${AUTH_CORE_PIN}" ] || AUTH_CORE_PIN="$(sed -n 's/^  "\([a-z-]*\)|[0-9a-f]*|hugmesh-auth-core|\([0-9.]*\)|.*$/\2/p' "${BOOT}" | head -1)"

  m2_neg() { # m2_neg <label> <corpus-dir> <expected-substring>
    local label="$1" corpus="$2" want="$3" out rc
    out="$(M2_SELFTEST_CHILD=1 STACK_SRC="${corpus}" bash "${SELF_M2}" 2>&1)"; rc=$?
    if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -F "${want}" >/dev/null; then
      ok "negative control bites: ${label}"
    else
      bad "negative control did NOT bite (rc=${rc}): ${label} — wanted '${want}'"
      printf '%s\n' "${out}" | sed -n '/2b) PIN drift/,/^-- 3)/p' | sed 's/^/           /'
    fi
  }

  if [ -z "${AUTH_CORE_PIN}" ]; then
    bad "2c could not read the auth-core pin out of the PINS array — controls not run"
  else
    # (i) TRUNCATED pom — the shape the FIX was written for, kept as the anchor.
    base_corpus "${NC}/trunc"
    healthy_pom "${NC}/trunc/hugmesh-workload-bff-api" "${AUTH_CORE_PIN}"
    head -c 240 "${NC}/trunc/hugmesh-workload-bff-api/pom.xml" > "${NC}/trunc.pom"
    mv "${NC}/trunc.pom" "${NC}/trunc/hugmesh-workload-bff-api/pom.xml"
    m2_neg "a truncated consumer pom among 11 healthy ones" "${NC}/trunc" \
           "hugmesh-workload-bff-api/pom.xml :: ParseError"

    # (ii) EMPTY pom — a fetch that produced a file and no content.
    base_corpus "${NC}/empty"
    mkdir -p "${NC}/empty/hugmesh-workload-bff-api"
    : > "${NC}/empty/hugmesh-workload-bff-api/pom.xml"
    m2_neg "a zero-byte consumer pom" "${NC}/empty" \
           "hugmesh-workload-bff-api/pom.xml :: ParseError"

    # (iii) A 404 PAGE saved as pom.xml. Parses; is not a POM. This is what a raw
    #       fetch of a private repo actually lands, and it is the reason the
    #       fetch path in 2b uses git-over-CI_REPOSITORY_URL rather than raw.
    base_corpus "${NC}/html"
    mkdir -p "${NC}/html/hugmesh-workload-bff-api"
    printf '<html><head><title>404: Not Found</title></head><body>404</body></html>\n' \
      > "${NC}/html/hugmesh-workload-bff-api/pom.xml"
    m2_neg "an HTML 404 page saved as pom.xml" "${NC}/html" \
           "root element is <html>"

    # (iv) A NAMESPACE-LESS pom carrying REAL drift. Well-formed, root <project>,
    #      and invisible to every namespaced lookup in the walk — so it used to
    #      contribute to neither `seen` nor DRIFT while eleven healthy consumers
    #      kept the anti-vacuity counter comfortably above zero.
    base_corpus "${NC}/nons"
    mkdir -p "${NC}/nons/hugmesh-workload-bff-api"
    cat > "${NC}/nons/hugmesh-workload-bff-api/pom.xml" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project>
  <modelVersion>4.0.0</modelVersion>
  <artifactId>hugmesh-workload-bff-api</artifactId>
  <dependencies>
    <dependency>
      <groupId>systems.hugmesh</groupId>
      <artifactId>hugmesh-auth-core</artifactId>
      <version>0.0.0-UNSERVED</version>
    </dependency>
  </dependencies>
</project>
POM
    m2_neg "a namespace-less pom hiding real drift behind 11 healthy consumers" "${NC}/nons" \
           "not the POM 4.0.0 <project>"

    # (v) OUTPUT-PROTOCOL FORGERY. A consumer DIRECTORY NAME is corpus-controlled
    #     data that the walker prints back. Embed a newline and a counterfeit
    #     record in it and an unescaped walker splits one finding into two lines,
    #     the second of which the filter silently eats.
    base_corpus "${NC}/inject"
    EVIL="${NC}/inject/$(printf 'hugmesh-evil\nnot-a-protocol-line')"
    healthy_pom "${EVIL}" "${AUTH_CORE_PIN}"
    head -c 240 "${EVIL}/pom.xml" > "${NC}/inject.pom"
    mv "${NC}/inject.pom" "${EVIL}/pom.xml"
    m2_neg "a consumer directory name that forges a line of the walker's output" "${NC}/inject" \
           'hugmesh-evil\nnot-a-protocol-line/pom.xml :: ParseError'

    # (vi) POSITIVE CONTROL. Without it, (i)-(v) could all be passing because the
    #      child run fails for some unrelated reason.
    base_corpus "${NC}/clean"
    CLEAN_OUT="$(M2_SELFTEST_CHILD=1 STACK_SRC="${NC}/clean" bash "${SELF_M2}" 2>&1)"; CLEAN_RC=$?
    if [ "${CLEAN_RC}" -eq 0 ]; then
      ok "positive control: an 11-consumer corpus that agrees with the pins PASSES (rc=0)"
    else
      bad "positive control FAILED (rc=${CLEAN_RC}) — (i)-(v) prove nothing if a clean corpus is also red"
      printf '%s\n' "${CLEAN_OUT}" | sed -n '/2b) PIN drift/,/^-- 3)/p' | sed 's/^/           /'
    fi
  fi

  # (vii) THE OPT-OUT MUST STAY A LOCAL ONE. M2_PIN_DRIFT_SKIP=1 exits 0 with no
  #       pin-drift checking at all; that is fine at a terminal and fatal in a
  #       pipeline. "CI never sets it" is only worth something if something fails
  #       when CI does — the same control tests/scripts/test-eso-seed-contract.sh
  #       runs on its own escape hatch.
  CI_YML="${REPO}/.gitlab-ci.yml"
  if [ ! -f "${CI_YML}" ]; then
    bad "(vii) ${CI_YML} not found — cannot prove CI never opts out of pin-drift"
  elif grep -qF "M2_PIN_DRIFT_SKIP" "${CI_YML}"; then
    bad "(vii) .gitlab-ci.yml mentions M2_PIN_DRIFT_SKIP — CI could switch the pin-drift leg off silently:"
    grep -nF "M2_PIN_DRIFT_SKIP" "${CI_YML}" | sed 's/^/         /'
  elif ! grep -qF "tests/stack/test-m2-bootstrap.sh" "${CI_YML}"; then
    bad "(vii) no .gitlab-ci.yml job runs tests/stack/test-m2-bootstrap.sh — the pin-drift leg is not wired in"
  else
    ok "(vii) .gitlab-ci.yml runs this suite and never sets M2_PIN_DRIFT_SKIP, so the CI path cannot skip pin-drift"
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
TMP="$(scratch_dir m2-probe)"
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

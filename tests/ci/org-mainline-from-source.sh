#!/usr/bin/env bash
#
# org-mainline-from-source.sh — build the intra-org Maven dependency graph FROM SOURCE
# (each repo's origin/main) and run every dependent's test suite against it.
#
# WHY THIS EXISTS
# --------------
# Each repo's own GitLab CI resolves the shared libraries (hugmesh-commons,
# hugmesh-auth-core, incl. the `tests` classifier) from the GitLab Maven *registry*
# via CI_JOB_TOKEN — i.e. it builds against the last PUBLISHED artifact, not against the
# current source of those libs. When a shared lib changes its API but is re-published
# under the SAME version ("content-bump-without-version-bump"), a dependent whose tests
# were NOT updated for that API change still compiles+passes in CI (against the stale
# published jar) while being RED against the lib's current source. The drift is invisible
# until someone builds the whole graph from source.
#
# That is exactly how three silent reds reached main on 2026-06-26 (mod-bff, auth-core,
# admin-bff) — all caught only by a manual from-source sweep. This script automates that
# sweep so the drift is caught mechanically. See the org memory
# `hugmesh-silent-red-main-rootcause` for the full diagnosis.
#
# WHAT IT DOES
# -----------
#   1. For each shared LIB: check out origin/main in a throwaway git worktree, set its
#      artifact <version> to the version dependents pin, and `mvn install` it into the
#      local ~/.m2 (so dependents resolve THIS source build, not the registry's).
#   2. For each DEPENDENT: check out origin/main in a worktree and `mvn -o test` it against
#      the freshly-installed libs. A repo that is red against current lib source fails here.
#   3. Print a per-repo PASS/FAIL table and exit non-zero if anything is red.
#
# It is deliberately offline for the dependent test runs (`-o`): all third-party deps are
# already cached, and the intra-org libs come from step 1, so a green run proves the graph
# is internally consistent at HEAD.
#
# USAGE
#   tests/ci/org-mainline-from-source.sh [dependent-repo ...]
#     (no args → the default DEPENDENTS list below)
#
# ENV
#   GITHUB_ROOT  parent dir holding the repo clones        (default: /home/magus/GitHub)
#   WORK         scratch dir for throwaway worktrees       (default: /var/tmp/portage/hugmesh-mainline-verify)
#   MVN          maven launcher                            (default: mvn)
#   SKIP_LIB_BUILD=1   reuse already-installed libs (faster re-runs)
#
# NOT -e on purpose: one red dependent must not abort the rest of the matrix.
set -uo pipefail

GITHUB_ROOT="${GITHUB_ROOT:-/home/magus/GitHub}"
WORK="${WORK:-/var/tmp/portage/hugmesh-mainline-verify}"
MVN="${MVN:-mvn}"

# Shared libs to build FROM SOURCE, in dependency order. Each is installed at BOTH its own
# <version> AND its <parent> version (see build_lib) — because dependents resolve the two
# libs at DIFFERENT coordinates: the commons MAIN jar resolves at 2.0.0 (its own version,
# pinned by hugmesh-parent's <hugmesh-commons.version>), while the auth-core MAIN jar
# resolves at 2.7.0 (the parent line, via the BOM) and some repos pin commons:2.7.0:tests.
# Installing at both (deduped) makes the from-source build the one actually consumed for
# every dependent's main-jar AND tests-classifier coordinate, self-correcting as the line bumps.
LIBS=(
  "hugmesh-commons"
  "hugmesh-auth-core"
)

# Dependents verified against the from-source libs (full `mvn test`).
DEPENDENTS_DEFAULT=(
  hugmesh-admin-bff-api
  hugmesh-mod-bff-api
  hugmesh-user-bff-api
  hugmesh-federation-api
  hugmesh-gateway
  hugmesh-forum-bff-api
  hugmesh-wiki-bff-api
  hugmesh-tube-bff-api
  hugmesh-owncast-bff-api
  hugmesh-actions
  hugmesh-remote-fragment
)

DEPENDENTS=("$@")
[ ${#DEPENDENTS[@]} -eq 0 ] && DEPENDENTS=("${DEPENDENTS_DEFAULT[@]}")

mkdir -p "$WORK"
declare -A RESULT
FAILED=0

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

# Add a <version> to the hugmesh-commons `tests`-classifier dep when a pom omits it and
# relies on a parent BOM entry that does not manage the classifier (a per-repo pom quirk
# that otherwise breaks the offline build). Idempotent; rewrites in place.
patch_commons_tests_version() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import sys, re
p = sys.argv[1]
s = open(p).read()
def fix(m):
    b = m.group(0)
    if 'hugmesh-commons' in b and '<classifier>tests</classifier>' in b and '<version>' not in b:
        b = b.replace('<artifactId>hugmesh-commons</artifactId>',
                      '<artifactId>hugmesh-commons</artifactId>\n      <version>${hugmesh-commons.version}</version>', 1)
    return b
open(p, 'w').write(re.sub(r'<dependency>.*?</dependency>', fix, s, flags=re.S))
PY
}

worktree_main() {  # repo  dest
  local repo="$1" dest="$2"
  local src="$GITHUB_ROOT/$repo"
  [ -d "$src/.git" ] || { echo "MISSING-CLONE"; return 1; }
  git -C "$src" fetch origin main -q 2>/dev/null || true
  git -C "$src" worktree remove "$dest" --force 2>/dev/null || true
  git -C "$src" worktree add --detach "$dest" origin/main -q 2>/dev/null || return 1
}
worktree_drop() { git -C "$GITHUB_ROOT/$1" worktree remove "$2" --force 2>/dev/null || rm -rf "$2"; }

build_lib() {  # repo
  local repo="$1"
  local dest="$WORK/$repo.lib"
  worktree_main "$repo" "$dest" || { echo "  cannot worktree $repo"; return 1; }
  # Install the lib from source at EVERY version a dependent might resolve it as. A
  # dependent resolves an intra-org lib in one of two ways, and they DIFFER per lib:
  #   - the lib's OWN <version> — e.g. the commons MAIN jar resolves to 2.0.0, because
  #     hugmesh-parent's <dependencyManagement> pins it via <hugmesh-commons.version>
  #     = 2.0.0 and dependents declare commons with NO explicit <version>; commons' own
  #     pom <version> is also 2.0.0, so 2.0.0 IS current source.
  #   - the lib's <parent> version (the org line, currently 2.7.0) — e.g. admin-bff
  #     resolves the auth-core MAIN jar at 2.7.0 via the parent BOM, and user-bff pins
  #     commons:2.7.0:tests.
  # Installing at BOTH (deduped) guarantees the from-source build is the one consumed no
  # matter which coordinate a given dependent resolves (main jar OR tests classifier),
  # instead of silently leaving the dependent on a STALE cached jar — the bug that made an
  # earlier single-version (parent-only) install reproduce drift rather than detect it.
  local versions
  versions=$(python3 - "$dest/pom.xml" <<'PY'
import sys, re
s = open(sys.argv[1]).read()
pm = re.search(r'<parent>.*?<version>([^<]+)</version>.*?</parent>', s, re.S)
parent = pm.group(1).strip() if pm else None
# project <version> = the FIRST <version> AFTER </parent>
i = s.find('</parent>')
om = re.search(r'<version>([^<]+)</version>', s[i:]) if i >= 0 else None
own = om.group(1).strip() if om else None
out = []
for v in (own, parent):          # own first (the most common MAIN-jar coordinate)
    if v and v not in out:
        out.append(v)
if not out:
    sys.exit(1)
print(' '.join(out))
PY
)
  [ -n "$versions" ] || { echo "  cannot derive versions for $repo"; worktree_drop "$repo" "$dest"; return 1; }
  # -DskipTests (NOT maven.test.skip): compiles the test sources + builds & installs the
  # `tests` classifier jar (downstream libs/dependents depend on it), only skipping
  # test EXECUTION. If a lib's own tests no longer compile, this fails loudly — itself a
  # real drift signal. Skip the static-analysis/enforcer plugins (we only need the
  # artifact + tests jar, not the lib's own quality gates) — faster + far less noisy.
  local skips="-DskipTests -Dspotbugs.skip=true -Dpmd.skip=true -Dcheckstyle.skip=true -Denforcer.skip=true"
  local rc=0 ver
  for ver in $versions; do
    # Set the project <version> (FIRST <version> after </parent>) to $ver, in place.
    python3 - "$dest/pom.xml" "$ver" <<'PY'
import sys, re
p, ver = sys.argv[1], sys.argv[2]
s = open(p).read()
i = s.find('</parent>')
head, tail = s[:i], s[i:]
tail = re.sub(r'<version>[^<]+</version>', f'<version>{ver}</version>', tail, count=1)
open(p, 'w').write(head + tail)
PY
    log "lib: $repo → install $ver (from source)"
    rm -rf "$HOME/.m2/repository/systems/hugmesh/$repo/$ver" 2>/dev/null || true
    # shellcheck disable=SC2086
    ( cd "$dest" && "$MVN" -q -o install $skips ) || ( cd "$dest" && "$MVN" -q install $skips )
    local r=$?
    [ "$r" -ne 0 ] && rc="$r"
  done
  worktree_drop "$repo" "$dest"
  return $rc
}

verify_dep() {  # repo
  local repo="$1"
  local dest="$WORK/$repo.dep"
  log "verify: $repo (mvn -o test vs from-source libs)"
  if ! worktree_main "$repo" "$dest"; then RESULT[$repo]="NO-CLONE"; FAILED=1; return; fi
  patch_commons_tests_version "$dest/pom.xml"
  local out; out=$( cd "$dest" && "$MVN" -o test 2>&1 )
  local line; line=$(echo "$out" | grep -E 'Tests run: [0-9]+, Failures: [0-9]+, Errors: [0-9]+, Skipped: [0-9]+$' | tail -1)
  if echo "$out" | grep 'BUILD SUCCESS' >/dev/null; then
    RESULT[$repo]="PASS  ${line:-(no test summary)}"
  else
    local why; why=$(echo "$out" | grep -E 'ERROR.*\.java:\[|cannot find symbol|cannot be applied|<<< FAILURE|<<< ERROR|Could not resolve|version.*is missing' | head -1 | sed 's#.*/##' | cut -c1-80)
    RESULT[$repo]="FAIL  ${why:-see log}"
    FAILED=1
  fi
  worktree_drop "$repo" "$dest"
}

# ── run ────────────────────────────────────────────────────────────────────────
if [ "${SKIP_LIB_BUILD:-0}" != "1" ]; then
  for lib in "${LIBS[@]}"; do
    build_lib "$lib" || { echo "FATAL: lib build failed: $lib"; exit 2; }
  done
fi

for dep in "${DEPENDENTS[@]}"; do verify_dep "$dep"; done

log "ORG MAINLINE (from source) — RESULTS"
for dep in "${DEPENDENTS[@]}"; do printf '  %-32s %s\n' "$dep" "${RESULT[$dep]:-?}"; done
echo
if [ "$FAILED" -eq 0 ]; then
  echo "✅ GREEN — the intra-org dependency graph is internally consistent at origin/main."
else
  echo "🔴 RED — a dependent is broken against current shared-lib SOURCE (drift). See logs above."
fi
exit "$FAILED"

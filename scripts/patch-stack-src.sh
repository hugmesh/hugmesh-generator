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
#     hugmesh.net' Dockerfile); match/anchor in a way that survives a
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

# ── patch: drop the UNRESOLVABLE pre-rename private dependency ────────────────
# A checkout can still declare `systems.snapdragon:snapdragon-commons` — the
# pre-HugMesh coordinate. Nothing publishes it any more: the artifact is
# `systems.hugmesh:hugmesh-commons` now, which is what m2-bootstrap.sh builds and
# serves, so the old coordinate resolves nowhere and the image build dies with
#   Could not find artifact systems.snapdragon:snapdragon-commons:jar:2.0.0 in central
# (live case: hugmesh-remote-fragment, whose own pom comment records the dep as
# "Currently unused by any class here — added purely for fleet-artifact alignment").
# Removing an UNUSED dependency is the conservative local repair; a checkout that
# actually IMPORTS commons would fail to compile and is out of scope for a patch.
# UPSTREAM FIX: the repo should drop (or re-coordinate) the dependency itself —
# once it does, the marker is gone and this becomes a natural no-op.
drop_pre_rename_commons_dep() { # <repo-checkout-dir>
  local f="$1/pom.xml"
  [ -f "${f}" ] || return 0
  # Match the COORDINATE ELEMENT, never prose: these poms carry long comments that
  # mention snapdragon-parent/-commons by name, and those must not trip the patch.
  grep -q '<groupId>systems\.snapdragon<' "${f}" || return 0   # clean / never affected
  if grep -rqE '(^|[^A-Za-z0-9_])import[[:space:]]+systems\.snapdragon\.' "$1/src" 2>/dev/null; then
    echo "  ! $(basename "$1")/pom.xml: pre-rename commons is IMPORTED in source — NOT patched (needs an upstream fix)" >&2
    return 0
  fi
  awk '
    # Buffer each <dependency> element and drop it whole when it names the
    # pre-rename private commons coordinate. Substring matches, so CRLF is fine.
    # NOTE the missing `next` on the opening rule: these poms also carry
    # SINGLE-LINE <dependency>…</dependency> entries, so the same line must fall
    # through to the close check below — skipping it swallowed every line up to
    # the next multi-line close (caught by the element-count guard in the caller).
    /<dependency>/ && !inblock { inblock=1; buf=""; grp=0; art=0 }
    inblock {
      buf = buf $0 "\n"
      if ($0 ~ /<groupId>systems\.snapdragon</)      grp=1
      if ($0 ~ /<artifactId>snapdragon-commons</)    art=1
      if ($0 ~ /<\/dependency>/) {
        if (grp && art) {
          print "    <!-- systems.snapdragon:snapdragon-commons dependency removed by"
          print "         scripts/patch-stack-src.sh: pre-rename coordinate, published nowhere. -->"
        } else printf "%s", buf
        inblock=0; buf=""
      }
      next
    }
    { print }
    END { if (inblock) printf "%s", buf }        # unterminated element: keep it verbatim
  ' "${f}" > "${f}.patch-tmp"
  # SAFETY: the rewrite must remove EXACTLY one <dependency> element and nothing
  # else. Anything other than that is a patch bug, not a repo problem — keep the
  # original and say so rather than hand `docker build` a mangled pom.
  local before after
  before="$(grep -o '<dependency>' "${f}" | wc -l)"
  after="$(grep -o '<dependency>' "${f}.patch-tmp" | wc -l)"
  if [ "$((before - after))" -ne 1 ]; then
    rm -f "${f}.patch-tmp"
    echo "  ! $(basename "$1")/pom.xml: patch would have removed $((before - after)) <dependency> elements (expected 1) — LEFT UNPATCHED" >&2
    return 0
  fi
  mv "${f}.patch-tmp" "${f}"
  if grep -q '<groupId>systems\.snapdragon<' "${f}"; then
    echo "  ! $(basename "$1")/pom.xml: pre-rename coordinate survived the patch — the build will fail" >&2
    return 0
  fi
  echo "  ~ $(basename "$1")/pom.xml: unresolvable pre-rename commons dependency dropped"
  patched=$((patched+1))
}

# ── patch: give a private-artifact consumer that ships NO settings.xml a way to
#           resolve one ────────────────────────────────────────────────────────
# hugmesh-gateway and hugmesh-actions DEPEND on the private hugmesh-commons
# (now net.hugmesh:hugmesh-commons; see the groupId note on the matcher below)
# but — unlike their eight BFF/federation siblings — ship no settings.xml, take
# no CI_API_V4_URL build arg and never pass `-s`. Maven therefore resolves from
# central only and the image build dies at the very first goal:
#   Could not find artifact systems.hugmesh:hugmesh-commons:jar:2.1.0 in central
# (These repos presumably build against runner-level settings in GitLab CI.)
#
# The injection is deliberately minimal: no existing RUN line is rewritten.
# MAVEN_ARGS (Maven 3.9+, honoured through the wrapper — verified in the build
# image) threads `-s` into EVERY mvnw invocation, so `dependency:go-offline` and
# `package` both pick it up. The settings file is written into the checkout and
# COPYed in, because these Dockerfiles copy selectively (mvnw/.mvn/pom.xml/src)
# rather than `COPY . .`.
#
# UPSTREAM FIX: these repos should ship the same settings.xml + ARG pair their
# siblings already have; the marker below then keeps this a no-op.
# BOTH groupId spellings must match. The private artifacts are mid-rename:
# hugmesh-commons already publishes as net.hugmesh (m2-bootstrap.sh PINS group
# path net/hugmesh) while hugmesh-parent/auth-core/build-config are still
# systems.hugmesh. Matching only `systems.hugmesh` made this detector blind to
# hugmesh-actions once its commons dep was renamed: the repo silently fell
# through as "no private dependency", never got its settings file wired, and the
# image build died at the first goal with
#   Could not find artifact net.hugmesh:hugmesh-commons:jar:2.1.0 in central
# — with no mention of the local registry, because `-s` was never threaded in.
POM_NEEDS_PRIVATE_AWK='
  /<dependency>/ && !inblock { inblock=1; hit=0 }
  inblock {
    if ($0 ~ /<groupId>(systems|net)\.hugmesh</) hit=1
    if ($0 ~ /<\/dependency>/) { if (hit) { found=1 }; inblock=0 }
    next
  }
  END { exit(found ? 0 : 1) }
'

wire_local_maven_registry() { # <repo-checkout-dir>
  local d="$1" df="$1/Dockerfile" pom="$1/pom.xml" settings="$1/hugmesh-local-settings.xml"
  [ -f "${df}" ] && [ -f "${pom}" ]                  || return 0
  [ ! -f "$1/settings.xml" ]                         || return 0   # already wired
  grep -q 'hugmesh-local-settings.xml' "${df}"       && return 0   # already patched
  awk "${POM_NEEDS_PRIVATE_AWK}" "${pom}"            || return 0   # no private dependency
  grep -q '^FROM .* AS build' "${df}"                || {
    echo "  ! $(basename "${d}")/Dockerfile: no '... AS build' stage to inject into — NOT patched" >&2
    return 0
  }

  cat > "${settings}" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Written by scripts/patch-stack-src.sh for the LOCAL docker-compose stack.
     Points maven at the local private-artifact registry container
     (tests/stack/m2-bootstrap.sh) using the same group-registry URL shape the
     sibling BFF repos' committed settings.xml use. The same-id mirror below
     neutralises Maven 3.9's maven-default-http-blocker, which would otherwise
     refuse the registry for being plain HTTP (it is a throwaway static server on
     the docker bridge, by design). No credentials: the registry ignores auth. -->
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <profiles>
    <profile>
      <id>hugmesh-local-registry</id>
      <repositories>
        <repository>
          <id>gitlab-maven</id>
          <url>${env.CI_API_V4_URL}/groups/${env.GITLAB_GROUP_ID}/-/packages/maven</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </repository>
      </repositories>
    </profile>
  </profiles>
  <activeProfiles><activeProfile>hugmesh-local-registry</activeProfile></activeProfiles>
  <mirrors>
    <mirror>
      <id>maven-default-http-blocker</id>
      <mirrorOf>__matches-no-repository__</mirrorOf>
      <url>http://0.0.0.0/</url>
    </mirror>
  </mirrors>
</settings>
XML

  awk '
    /^FROM .* AS build/ && !done {
      print
      print "# ── injected by scripts/patch-stack-src.sh (LOCAL stack cold build) ───────────"
      print "# This service depends on org-private systems.hugmesh:* artifacts but ships no"
      print "# settings.xml, so maven resolves from central only and the first goal fails."
      print "# MAVEN_ARGS (Maven 3.9+) threads the injected settings into EVERY mvnw call,"
      print "# so no RUN line above needs rewriting."
      print "ARG CI_API_V4_URL"
      print "ARG GITLAB_GROUP_ID"
      print "ENV CI_API_V4_URL=${CI_API_V4_URL} \\"
      print "    GITLAB_GROUP_ID=${GITLAB_GROUP_ID} \\"
      print "    MAVEN_ARGS=\"-s hugmesh-local-settings.xml\""
      done=1
      next
    }
    # the settings file must land before the first goal that resolves anything
    /^COPY pom.xml/ && !copied { print; print "COPY hugmesh-local-settings.xml ./"; copied=1; next }
    { print }
    END { if (!copied) exit 3 }
  ' "${df}" > "${df}.patch-tmp" || true
  if ! grep -q 'COPY hugmesh-local-settings.xml' "${df}.patch-tmp"; then
    rm -f "${df}.patch-tmp" "${settings}"
    echo "  ! $(basename "${d}")/Dockerfile: no 'COPY pom.xml' anchor — NOT patched (needs an upstream fix)" >&2
    return 0
  fi
  mv "${df}.patch-tmp" "${df}"
  echo "  ~ $(basename "${d}")/Dockerfile: local private-maven registry wired (settings + MAVEN_ARGS)"
  patched=$((patched+1))
}

# ── patch: collapse the module-federation version skew that breaks the Angular
#           host build ─────────────────────────────────────────────────────────
# hugmesh-host-shell's lockfile resolves TWO copies of @softarc/native-federation:
# 4.1.3 hoisted to the top level, and the (newer) one @angular-architects/native-
# federation nests for itself. @softarc/native-federation-orchestrator is hoisted
# alongside the OLD copy, so its typings resolve against 4.1.3 and `npm run build`
# dies before a single app file compiles:
#   TS2724: '"@softarc/native-federation/domain"' has no exported member named
#           'DenseSharedInfo'. Did you mean 'SharedInfo'?
# `npm ci` does not help — the skew is IN the committed lock — and the Dockerfile
# runs a floating `npm install`, so the failure is not even reproducible over time.
#
# Fix: force ONE copy, at exactly the version @angular-architects itself nests
# (read out of the repo's own lock — never a version invented here). `npm pkg set`
# is npm's own package.json editor, so no JSON tooling is needed on the host and
# the edit happens inside the build image.
#
# UPSTREAM FIX: the repo should pin this in its own package.json/lock. Only a
# checkout that actually exhibits the skew is touched, so a fixed lock = no-op.
nested_federation_version() { # <lock-file> -> version, or "" if not nested
  awk '
    $0 ~ /"node_modules\/@angular-architects\/native-federation\/node_modules\/@softarc\/native-federation":/ { hit=1; next }
    hit && match($0, /"version"[[:space:]]*:[[:space:]]*"[^"]+"/) {
      v = substr($0, RSTART, RLENGTH); sub(/.*"version"[[:space:]]*:[[:space:]]*"/, "", v); sub(/"$/, "", v)
      print v; exit
    }
  ' "$1"
}

top_level_federation_version() { # <lock-file> -> version, or ""
  awk '
    $0 ~ /"node_modules\/@softarc\/native-federation":/ { hit=1; next }
    hit && match($0, /"version"[[:space:]]*:[[:space:]]*"[^"]+"/) {
      v = substr($0, RSTART, RLENGTH); sub(/.*"version"[[:space:]]*:[[:space:]]*"/, "", v); sub(/"$/, "", v)
      print v; exit
    }
  ' "$1"
}

pin_federation_to_one_copy() { # <repo-checkout-dir>
  local d="$1" df="$1/Dockerfile" lock="$1/package-lock.json"
  [ -f "${df}" ] && [ -f "${lock}" ]                     || return 0
  [ -f "$1/package.json" ]                               || return 0
  grep -q 'overrides.@softarc/native-federation' "${df}" && return 0   # already patched
  local nested top
  nested="$(nested_federation_version "${lock}")"
  top="$(top_level_federation_version "${lock}")"
  [ -n "${nested}" ] && [ -n "${top}" ]                  || return 0   # no two copies
  [ "${nested}" != "${top}" ]                            || return 0   # already one version
  grep -qE '^RUN npm (install|ci)' "${df}"               || {
    echo "  ! $(basename "${d}")/Dockerfile: no 'RUN npm install|ci' to pin before — NOT patched" >&2
    return 0
  }
  awk -v ver="${nested}" '
    /^RUN npm (install|ci)/ && !done {
      print "# ── injected by scripts/patch-stack-src.sh (LOCAL stack build) ───────────────"
      print "# This lock resolves two copies of @softarc/native-federation; the hoisted one"
      print "# is older than the copy @angular-architects/native-federation nests, so the"
      print "# orchestrator typings fail to compile (TS2724 DenseSharedInfo). Collapse them"
      print "# onto the nested version — read from this repo'\''s own lockfile."
      print "RUN npm pkg set '\''overrides.@softarc/native-federation'\''=" ver
      done=1
    }
    { print }
    END { if (!done) exit 3 }
  ' "${df}" > "${df}.patch-tmp" || true
  if ! grep -q 'overrides.@softarc/native-federation' "${df}.patch-tmp"; then
    rm -f "${df}.patch-tmp"
    echo "  ! $(basename "${d}")/Dockerfile: federation pin could not be injected — NOT patched" >&2
    return 0
  fi
  mv "${df}.patch-tmp" "${df}"
  echo "  ~ $(basename "${d}")/Dockerfile: @softarc/native-federation pinned to ${nested} (was ${top} hoisted)"
  patched=$((patched+1))
}

# ── patch: two defects in the gateway's own Cassandra migrations ──────────────
# hugmesh-gateway's migration 005 creates gateway_route_access with a column
# literally named `allow`, which is a RESERVED keyword in Cassandra (the cluster
# and this stack both run 5.x), so the statement does not even parse:
#   CassandraQuerySyntaxException: line 1:139 mismatched input 'allow' expecting ')'
# The migration runner treats that as fatal, so ALL THREE gateways crash-loop and
# the platform front door never opens. Quoting makes the identifier legal while
# keeping the column name byte-identical (a quoted lowercase identifier is the
# same column as an unquoted one), so no data or query shape changes.
# UPSTREAM FIX: quote it (or rename the column) in the repo — the marker below
# then stops matching and this is a no-op.
# Same file, second defect class: the four schema migrations that ADD a column do
# so unconditionally. The three gateways share ONE keyspace and start together, so
# they race the same ALTER; the losers die with
#   InvalidQueryException: Column with name 'strip_prefix' already exists
# and stay dead (compose does not restart them the way a k8s pod would). The
# schema_migrations gate is not atomic across concurrent starters. `ADD IF NOT
# EXISTS` (Cassandra 4.0+, verified on the 5.x this stack runs) makes each ALTER
# idempotent, so whoever loses the race simply no-ops.
# UPSTREAM FIX: the same one-word change in the repo.
make_cassandra_alters_idempotent() { # <migrations-file>
  local f="$1" before after
  before="$(grep -c 'ALTER TABLE [a-z_]* ADD [a-z_]' "${f}" || true)"
  [ "${before}" != "0" ] || return 0
  sed -i -E 's/(ALTER TABLE [a-z_]+ ADD )([a-z_]+ )/\1IF NOT EXISTS \2/g' "${f}"
  after="$(grep -c 'ALTER TABLE [a-z_]* ADD IF NOT EXISTS' "${f}" || true)"
  [ "${after}" = "${before}" ] || {
    echo "  ! $(basename "$(dirname "${f}")"): only ${after}/${before} ALTERs made idempotent" >&2
    return 0
  }
  echo "  ~ CassandraSchemaMigrations.java: ${after} ALTER(s) made idempotent (ADD IF NOT EXISTS)"
  return 0
}

patch_gateway_cassandra_migrations() { # <repo-checkout-dir>
  local f
  # `|| true`: under `set -o pipefail` a missing src/ makes find exit 1, which would
  # abort the whole patch pass at the first UI checkout (no src/ dir) — silently,
  # taking `make stack-up` with it.
  f="$(find "$1/src" -name CassandraSchemaMigrations.java 2>/dev/null | head -1 || true)"
  [ -n "${f}" ] && [ -f "${f}" ] || return 0

  # (a) the reserved column name
  if grep -q '"  allow boolean,"' "${f}"; then
    sed -i 's/"  allow boolean,"/"  \\"allow\\" boolean,"/' "${f}"
    if grep -q '\\"allow\\" boolean' "${f}"; then
      echo "  ~ $(basename "$1")/CassandraSchemaMigrations.java: reserved column 'allow' quoted"
      patched=$((patched+1))
    else
      echo "  ! $(basename "$1"): could not quote the reserved 'allow' column — the gateway will not boot" >&2
    fi
  fi

  # (b) the racing ALTERs
  local before after
  before="$(grep -c 'ALTER TABLE [a-z_]* ADD [a-z_]' "${f}" || true)"
  if [ "${before}" != "0" ]; then
    sed -i -E 's/(ALTER TABLE [a-z_]+ ADD )([a-z_]+ )/\1IF NOT EXISTS \2/g' "${f}"
    after="$(grep -c 'ALTER TABLE [a-z_]* ADD IF NOT EXISTS' "${f}" || true)"
    if [ "${after}" = "${before}" ]; then
      echo "  ~ $(basename "$1")/CassandraSchemaMigrations.java: ${after} ALTER(s) made idempotent (ADD IF NOT EXISTS)"
      patched=$((patched+1))
    else
      echo "  ! $(basename "$1"): only ${after}/${before} ALTERs made idempotent" >&2
    fi
  fi
}

# ── patch: give every path-mounted UI the base-href login-ui already has ──────
# The fe-gateway mounts each UI under a path (/admin/, /wiki/, /social/forum/ …),
# but only login-ui builds with `-- --base-href=/login/`. Every other UI ships
# <base href="/"> with RELATIVE hashed assets, so direct navigation makes the
# browser fetch /main-<hash>.js from the WEBROOT — the /** catch-all forwards
# that to the host shell, whose SPA fallback returns index.html as text/html,
# and the page renders COMPLETELY BLANK (live case: /admin/ and /api-docs/;
# login was the ONLY page that worked, for exactly this reason).
# UPSTREAM FIX: one flag per UI repo Dockerfile, copying login-ui's pattern.
#
# The key is the path RELATIVE TO STACK_SRC, not a bare directory basename. Most
# UIs ARE their own checkout, so the two are the same string — but character-forge
# is one MULTI-SURFACE repo (BFF root + godot/ + frontend/) whose UI image builds
# from hugmesh-character-forge-bff-api/frontend. Keyed on basename, that checkout
# asked the table about "hugmesh-character-forge-bff-api" (the BFF), got "", and
# the nested UI was never even considered — so the /character-forge/ page would
# have shipped <base href="/">: exactly the defect #459 fixed everywhere else,
# and the second reason that slug was held out of the default compose set.
# A nested key must stay ONE level deep — that is all the scan loop walks.
# Keying on the RELATIVE path (not the basename) is also what makes that extra
# level safe: a subdir only ever matches if the table names it with its parent.
ui_base_href() { # <dir relative to STACK_SRC> -> mount path ("" = not a path-mounted UI)
  case "$1" in
    hugmesh-admin-ui)             printf '/admin/' ;;
    hugmesh-mod-ui)               printf '/mod/' ;;
    hugmesh-user-ui)              printf '/user/' ;;
    hugmesh-api-docs)             printf '/api-docs/' ;;
    hugmesh-wiki-ui)              printf '/wiki/' ;;
    hugmesh-owncast-ui)           printf '/owncast/' ;;
    hugmesh-tube-ui)              printf '/tube/' ;;
    hugmesh-character-studio-ui)  printf '/character-studio/' ;;
    hugmesh-forum-ui)             printf '/social/forum/' ;;
    hugmesh-matrix-ui)            printf '/social/matrix/' ;;
    hugmesh-mastodon-ui)          printf '/social/mastodon/' ;;
    # nested UI: a UI image built from a SUBDIR of another checkout (see above).
    hugmesh-character-forge-bff-api/frontend) printf '/character-forge/' ;;
    *)                            printf '' ;;
  esac
}

# The caller passes the table key, rather than this deriving it by stripping a
# "${STACK_SRC}/" prefix off the path: STACK_SRC is operator-supplied (Makefile
# var, studio's directory picker, $1) and a single TRAILING SLASH on it makes that
# arithmetic leave a stray leading "/" on every key, missing the table for EVERY
# UI — silently un-patching the ones that already worked. The scan loop below
# knows the two path components for a fact, so it just says so.
fix_ui_base_href() { # <ui-dir: a checkout, or a UI subdir of one> <its path relative to STACK_SRC>
  local d="${1%/}" rel="$2" df slug
  df="${d}/Dockerfile"
  slug="$(ui_base_href "${rel}")"
  [ -n "${slug}" ] && [ -f "${df}" ]      || return 0
  grep -q -- '--base-href' "${df}"        && return 0   # already correct (login-ui pattern)
  grep -qE '^RUN npm run build' "${df}"   || {
    echo "  ! ${rel}/Dockerfile: no single-line 'RUN npm run build' to anchor --base-href — NOT patched" >&2
    return 0
  }
  sed -i -E "s#^(RUN npm run build[A-Za-z:_-]*)( --prod)?\$#\1\2 -- --base-href=${slug}#" "${df}"
  grep -q -- "--base-href=${slug}" "${df}" || {
    echo "  ! ${rel}/Dockerfile: --base-href injection failed" >&2
    return 0
  }
  echo "  ~ ${rel}/Dockerfile: --base-href=${slug} injected (login-ui pattern)"
  patched=$((patched+1))
}

if [ ! -d "${STACK_SRC}" ]; then
  echo "==> patch-stack-src: ${STACK_SRC} does not exist (nothing to patch)"
  exit 0
fi

for dir in "${STACK_SRC}"/*/; do
  [ -d "${dir}" ] || continue
  scanned=$((scanned+1))
  repo="$(basename "${dir}")"
  unblock_http_registry "${dir%/}"
  drop_pre_rename_commons_dep "${dir%/}"
  wire_local_maven_registry "${dir%/}"
  pin_federation_to_one_copy "${dir%/}"
  fix_ui_base_href "${dir%/}" "${repo}"
  # One extra level, for NESTED UIs only: character-forge's UI image builds from
  # hugmesh-character-forge-bff-api/frontend, which this top-level walk never
  # visits. ui_base_href's table decides — every other subdir (src/, godot/,
  # target/ …) costs one lookup that returns "" and returns immediately. Unglobbed
  # dotfiles keep .git/ out of it for free.
  for sub in "${dir%/}"/*/; do
    [ -d "${sub}" ] || continue
    fix_ui_base_href "${sub%/}" "${repo}/$(basename "${sub}")"
  done
  patch_gateway_cassandra_migrations "${dir%/}"
done
echo "==> patch-stack-src: ${scanned} checkout(s) scanned, ${patched} patched"

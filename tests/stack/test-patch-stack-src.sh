#!/usr/bin/env bash
# test-patch-stack-src.sh — unit-tests scripts/patch-stack-src.sh against synthetic
# checkouts. No network, no docker, no cloned repos: every fixture is written here.
#
# The patch pass rewrites SOURCE FILES in ./.stack-src that `docker compose build`
# then consumes, so a sloppy rewrite silently corrupts an image build rather than
# failing loudly. The case that motivated this suite: the pom-dependency remover
# treated `<dependency>` as always opening a MULTI-LINE element, so on a pom whose
# other dependencies are written on ONE line it swallowed every line between the
# first single-line dependency and the next multi-line close — 101 lines gone from
# a 1-dependency edit, and the result still parsed as valid XML.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
PATCH_SH="${REPO_ROOT}/scripts/patch-stack-src.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass=0 fail=0
ok()   { echo "  ok   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1" >&2; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# ── fixture: a pom shaped like hugmesh-remote-fragment's — single-line deps around
#    a multi-line pre-rename private dependency, and prose that NAMES the old
#    coordinate (which must not itself trigger anything).
make_pom() { # <dir> <with-stale-dep: yes|no>
  mkdir -p "$1"
  {
    echo '<project>'
    echo '  <dependencies>'
    # ONE single-line dependency here, deliberately: an odd count before the
    # multi-line element below is what exposes a rewriter that assumes
    # <dependency> always opens a multi-line block (it then stays "open" across
    # the prose and swallows it together with the element it was meant to drop).
    echo '    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-webflux</artifactId></dependency>'
    echo '    <!-- snapdragon-commons — prose mentioning snapdragon-parent and the old'
    echo '         systems.snapdragon coordinate. Comments must survive verbatim. -->'
    if [ "$2" = "yes" ]; then
      echo '    <dependency>'
      echo '      <groupId>systems.snapdragon</groupId>'
      echo '      <artifactId>snapdragon-commons</artifactId>'
      echo '      <version>2.0.0</version>'
      echo '      <exclusions>'
      echo '        <exclusion>'
      echo '          <groupId>org.postgresql</groupId>'
      echo '          <artifactId>postgresql</artifactId>'
      echo '        </exclusion>'
      echo '      </exclusions>'
      echo '    </dependency>'
    fi
    echo '    <dependency><groupId>com.fasterxml.jackson.core</groupId><artifactId>jackson-databind</artifactId></dependency>'
    echo '    <dependency>'
    echo '      <groupId>io.projectreactor</groupId>'
    echo '      <artifactId>reactor-test</artifactId>'
    echo '    </dependency>'
    echo '  </dependencies>'
    echo '</project>'
  } > "$1/pom.xml"
}

deps() { grep -o '<dependency>' "$1" | wc -l | tr -d ' '; }

echo "== 1. the stale dependency is removed, and NOTHING else is =="
SRC="${WORK}/a"; make_pom "${SRC}/svc" yes
before_deps="$(deps "${SRC}/svc/pom.xml")"
bash "${PATCH_SH}" "${SRC}" >/dev/null
check "exactly one <dependency> element removed" \
      "$(( before_deps - $(deps "${SRC}/svc/pom.xml") ))" "1"
check "the pre-rename coordinate is gone" \
      "$(grep -c '<groupId>systems\.snapdragon<' "${SRC}/svc/pom.xml" || true)" "0"
check "the single-line webflux dependency survived" \
      "$(grep -c 'spring-boot-starter-webflux' "${SRC}/svc/pom.xml" || true)" "1"
check "the single-line jackson dependency survived" \
      "$(grep -c 'jackson-databind' "${SRC}/svc/pom.xml" || true)" "1"
check "the trailing multi-line dependency survived" \
      "$(grep -c 'reactor-test' "${SRC}/svc/pom.xml" || true)" "1"
check "prose naming the old coordinate survived" \
      "$(grep -c 'prose mentioning snapdragon-parent' "${SRC}/svc/pom.xml" || true)" "1"
if python3 -c "import xml.etree.ElementTree as ET,sys; ET.parse(sys.argv[1])" \
     "${SRC}/svc/pom.xml" 2>/dev/null; then ok "the result is well-formed XML"
else bad "the result is well-formed XML"; fi

echo "== 2. idempotent: a second pass is a no-op =="
cp "${SRC}/svc/pom.xml" "${WORK}/after-first"
bash "${PATCH_SH}" "${SRC}" >/dev/null
if diff -q "${WORK}/after-first" "${SRC}/svc/pom.xml" >/dev/null; then ok "second pass changed nothing"
else bad "second pass changed the file"; fi

echo "== 3. a clean checkout is untouched =="
SRC2="${WORK}/b"; make_pom "${SRC2}/svc" no
cp "${SRC2}/svc/pom.xml" "${WORK}/clean-before"
bash "${PATCH_SH}" "${SRC2}" >/dev/null
if diff -q "${WORK}/clean-before" "${SRC2}/svc/pom.xml" >/dev/null; then ok "no stale coordinate => byte-identical"
else bad "a clean pom was rewritten"; fi

echo "== 4. a checkout that IMPORTS the old package is refused, not mangled =="
SRC3="${WORK}/c"; make_pom "${SRC3}/svc" yes
mkdir -p "${SRC3}/svc/src/main/java"
printf 'import systems.snapdragon.commons.Roles;\n' > "${SRC3}/svc/src/main/java/App.java"
cp "${SRC3}/svc/pom.xml" "${WORK}/imported-before"
out="$(bash "${PATCH_SH}" "${SRC3}" 2>&1 || true)"
if diff -q "${WORK}/imported-before" "${SRC3}/svc/pom.xml" >/dev/null; then ok "pom left alone when the package is imported"
else bad "patched a pom whose source imports the package"; fi
case "${out}" in *"IMPORTED in source"*) ok "the refusal is reported" ;;
                 *) bad "the refusal is reported (got: ${out})" ;; esac

echo "== 5. the http-blocker settings.xml patch still applies + is idempotent =="
SRC4="${WORK}/d"; mkdir -p "${SRC4}/svc"
printf '<settings>\n  <servers><server><id>gitlab-maven</id></server></servers>\n  <!-- ${env.CI_API_V4_URL} -->\n</settings>\n' \
  > "${SRC4}/svc/settings.xml"
bash "${PATCH_SH}" "${SRC4}" >/dev/null
check "mirror injected once" \
      "$(grep -c 'maven-default-http-blocker' "${SRC4}/svc/settings.xml" || true)" "1"
bash "${PATCH_SH}" "${SRC4}" >/dev/null
check "still exactly once after a second pass" \
      "$(grep -c 'maven-default-http-blocker' "${SRC4}/svc/settings.xml" || true)" "1"

# ── fixture: a private-artifact consumer that ships NO settings.xml (the
#    hugmesh-gateway / hugmesh-actions shape: selective COPY, not `COPY . .`).
make_consumer() { # <dir> <private-dep: yes|no> <anchor: yes|no>
  mkdir -p "$1"
  {
    echo '<project>'
    echo '  <groupId>systems.hugmesh</groupId>'      # its OWN coords are not a dependency
    echo '  <artifactId>gateway</artifactId>'
    echo '  <dependencies>'
    echo '    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-webflux</artifactId></dependency>'
    if [ "$2" = "yes" ]; then
      echo '    <dependency>'
      echo '      <groupId>systems.hugmesh</groupId>'
      echo '      <artifactId>hugmesh-commons</artifactId>'
      echo '      <version>2.1.0</version>'
      echo '    </dependency>'
    fi
    echo '  </dependencies>'
    echo '</project>'
  } > "$1/pom.xml"
  {
    echo 'FROM eclipse-temurin:25-jdk AS build'
    echo 'WORKDIR /work'
    echo 'COPY mvnw mvnw.cmd ./'
    [ "$3" = "yes" ] && echo 'COPY pom.xml ./'
    echo 'RUN ./mvnw -B dependency:go-offline'
    echo 'COPY src src'
    echo 'RUN ./mvnw -B package -DskipTests'
    echo 'FROM eclipse-temurin:25-jre'
  } > "$1/Dockerfile"
}

echo "== 6. a private-artifact consumer with no settings.xml gets wired =="
SRC5="${WORK}/e"; make_consumer "${SRC5}/gw" yes yes
bash "${PATCH_SH}" "${SRC5}" >/dev/null
if [ -f "${SRC5}/gw/hugmesh-local-settings.xml" ]; then ok "settings file written"
else bad "settings file written"; fi
check "the registry URL uses the group-registry shape"       "$(grep -c 'groups/${env.GITLAB_GROUP_ID}/-/packages/maven' "${SRC5}/gw/hugmesh-local-settings.xml" || true)" "1"
check "the http-blocker is neutralised"       "$(grep -c '<id>maven-default-http-blocker</id>' "${SRC5}/gw/hugmesh-local-settings.xml" || true)" "1"
check "ARG CI_API_V4_URL injected"       "$(grep -c '^ARG CI_API_V4_URL$' "${SRC5}/gw/Dockerfile" || true)" "1"
check "MAVEN_ARGS injected"       "$(grep -c 'MAVEN_ARGS=' "${SRC5}/gw/Dockerfile" || true)" "1"
copy_ln="$(grep -n 'COPY hugmesh-local-settings.xml' "${SRC5}/gw/Dockerfile" | cut -d: -f1)"
mvnw_ln="$(grep -n 'RUN ./mvnw' "${SRC5}/gw/Dockerfile" | head -1 | cut -d: -f1)"
if [ -n "${copy_ln}" ] && [ "${copy_ln}" -lt "${mvnw_ln}" ]; then ok "the settings COPY lands before the first mvnw goal"
else bad "the settings COPY lands before the first mvnw goal (copy=${copy_ln} mvnw=${mvnw_ln})"; fi
arg_ln="$(grep -n '^ARG CI_API_V4_URL$' "${SRC5}/gw/Dockerfile" | cut -d: -f1)"
from_ln="$(grep -n 'AS build' "${SRC5}/gw/Dockerfile" | cut -d: -f1)"
if [ "${arg_ln}" -gt "${from_ln}" ]; then ok "ARGs land inside the build stage"
else bad "ARGs land inside the build stage"; fi

echo "== 7. idempotent =="
cp "${SRC5}/gw/Dockerfile" "${WORK}/wired-before"
bash "${PATCH_SH}" "${SRC5}" >/dev/null
if diff -q "${WORK}/wired-before" "${SRC5}/gw/Dockerfile" >/dev/null; then ok "second pass changed nothing"
else bad "second pass changed the Dockerfile"; fi

echo "== 8. a checkout with NO private dependency is left alone =="
SRC6="${WORK}/f"; make_consumer "${SRC6}/gw" no yes
cp "${SRC6}/gw/Dockerfile" "${WORK}/nodep-before"
bash "${PATCH_SH}" "${SRC6}" >/dev/null
if diff -q "${WORK}/nodep-before" "${SRC6}/gw/Dockerfile" >/dev/null; then ok "own systems.hugmesh coords do not count as a dependency"
else bad "patched a checkout with no private dependency"; fi
if [ ! -f "${SRC6}/gw/hugmesh-local-settings.xml" ]; then ok "no stray settings file"
else bad "no stray settings file"; fi

echo "== 9. a checkout that ALREADY ships settings.xml is left alone =="
SRC7="${WORK}/g"; make_consumer "${SRC7}/gw" yes yes
printf '<settings><!-- ${env.CI_API_V4_URL} --></settings>\n' > "${SRC7}/gw/settings.xml"
cp "${SRC7}/gw/Dockerfile" "${WORK}/own-before"
bash "${PATCH_SH}" "${SRC7}" >/dev/null
if diff -q "${WORK}/own-before" "${SRC7}/gw/Dockerfile" >/dev/null; then ok "the repo's own settings.xml wins"
else bad "overwrote a repo that ships its own settings.xml"; fi

echo "== 10. no COPY anchor => refused, nothing left behind =="
SRC8="${WORK}/h"; make_consumer "${SRC8}/gw" yes no
cp "${SRC8}/gw/Dockerfile" "${WORK}/anchorless-before"
out2="$(bash "${PATCH_SH}" "${SRC8}" 2>&1 || true)"
if diff -q "${WORK}/anchorless-before" "${SRC8}/gw/Dockerfile" >/dev/null; then ok "Dockerfile untouched"
else bad "rewrote a Dockerfile with no anchor"; fi
if [ ! -f "${SRC8}/gw/hugmesh-local-settings.xml" ]; then ok "the orphan settings file is cleaned up"
else bad "left an orphan settings file"; fi
case "${out2}" in *"no 'COPY pom.xml' anchor"*) ok "the refusal is reported" ;;
                  *) bad "the refusal is reported (got: ${out2})" ;; esac

# ── fixture: an Angular UI checkout whose lock resolves two copies of
#    @softarc/native-federation (the hugmesh-host-shell shape).
make_ui() { # <dir> <top-level-version> <nested-version|none>
  mkdir -p "$1"
  printf '{ "name": "host", "dependencies": { "@angular-architects/native-federation": "^22.0.5" } }\n' > "$1/package.json"
  {
    echo '{'
    echo '  "packages": {'
    echo '    "node_modules/@softarc/native-federation": {'
    echo "      \"version\": \"$2\""
    echo '    },'
    echo '    "node_modules/@softarc/native-federation-orchestrator": {'
    echo '      "version": "4.5.1"'
    echo '    }'
    if [ "$3" != "none" ]; then
      echo '    ,"node_modules/@angular-architects/native-federation/node_modules/@softarc/native-federation": {'
      echo "      \"version\": \"$3\""
      echo '    }'
    fi
    echo '  }'
    echo '}'
  } > "$1/package-lock.json"
  {
    echo 'FROM node:24-alpine AS build'
    echo 'WORKDIR /usr/src/app'
    echo 'COPY package*.json ./'
    echo 'RUN npm install'
    echo 'COPY . .'
    echo 'RUN npm run build --prod'
  } > "$1/Dockerfile"
}

echo "== 11. two copies of native-federation are collapsed onto the nested one =="
SRC9="${WORK}/i"; make_ui "${SRC9}/ui" 4.1.3 4.3.1
bash "${PATCH_SH}" "${SRC9}" >/dev/null
check "the pin uses the NESTED version from the repo's own lock" \
      "$(grep -c "overrides.@softarc/native-federation'=4.3.1" "${SRC9}/ui/Dockerfile" || true)" "1"
pin_ln="$(grep -n 'npm pkg set' "${SRC9}/ui/Dockerfile" | cut -d: -f1)"
inst_ln="$(grep -n '^RUN npm install' "${SRC9}/ui/Dockerfile" | head -1 | cut -d: -f1)"
if [ -n "${pin_ln}" ] && [ "${pin_ln}" -lt "${inst_ln}" ]; then ok "the pin runs before npm install"
else bad "the pin runs before npm install (pin=${pin_ln} install=${inst_ln})"; fi

echo "== 12. idempotent =="
cp "${SRC9}/ui/Dockerfile" "${WORK}/pinned-before"
bash "${PATCH_SH}" "${SRC9}" >/dev/null
if diff -q "${WORK}/pinned-before" "${SRC9}/ui/Dockerfile" >/dev/null; then ok "second pass changed nothing"
else bad "second pass changed the Dockerfile"; fi

echo "== 13. one consistent copy => untouched =="
SRC10="${WORK}/j"; make_ui "${SRC10}/ui" 4.3.1 4.3.1
cp "${SRC10}/ui/Dockerfile" "${WORK}/same-before"
bash "${PATCH_SH}" "${SRC10}" >/dev/null
if diff -q "${WORK}/same-before" "${SRC10}/ui/Dockerfile" >/dev/null; then ok "identical versions are not a skew"
else bad "patched a checkout with a single consistent version"; fi

echo "== 14. no nested copy at all => untouched =="
SRC11="${WORK}/k"; make_ui "${SRC11}/ui" 4.2.0 none
cp "${SRC11}/ui/Dockerfile" "${WORK}/nonested-before"
bash "${PATCH_SH}" "${SRC11}" >/dev/null
if diff -q "${WORK}/nonested-before" "${SRC11}/ui/Dockerfile" >/dev/null; then ok "nothing to collapse => no invented version"
else bad "patched a checkout with no nested copy"; fi

echo "== 15. a checkout with no src/ tree does not abort the pass =="
# REGRESSION: `find <dir>/src` exits 1 when src/ is absent (every UI checkout), and
# under `set -o pipefail` that aborted the whole patch pass at the first such repo —
# silently, taking `make stack-up` down with it.
SRC12="${WORK}/l"
mkdir -p "${SRC12}/ui-no-src" "${SRC12}/zzz-later"
printf 'FROM node:24-alpine AS build\n' > "${SRC12}/ui-no-src/Dockerfile"
printf '<settings><!-- ${env.CI_API_V4_URL} --></settings>\n' > "${SRC12}/zzz-later/settings.xml"
if bash "${PATCH_SH}" "${SRC12}" >/dev/null 2>&1; then ok "the pass completes (exit 0)"
else bad "the pass aborted on a checkout with no src/"; fi
check "checkouts AFTER the src-less one are still patched" \
      "$(grep -c 'maven-default-http-blocker' "${SRC12}/zzz-later/settings.xml" || true)" "1"

echo
echo "== ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]

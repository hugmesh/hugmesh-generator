#!/usr/bin/env bash
# test-stack-golive-knobs.sh — four traps a second operator hit bringing the prod-build local stack up
# behind a tunnel and a Tor onion, and the guards that keep them fixed. No docker daemon needed except
# gen-build-network.sh (`docker compose config`), which is skipped when compose is absent.
#
#   (1) PUBLIC_BIND_ADDR: the front door (fe-gateway, https-front, Anubis) publishes on
#       ${PUBLIC_BIND_ADDR:-0.0.0.0} (unchanged default = every interface), and the Makefile threads it.
#   (2) GAMES=1 with no games checkout stops BEFORE the build with a message naming GAMES_SRC, and passes
#       when GAMES_SRC points at one.
#   (3) BUILD_NETWORK=host: stack-up and stack-build generate and include the overlay; without the knob
#       neither mentions it; the generator rejects a value buildkit refuses and lists only buildable services.
#   (4) seed-e2e.sh does not ask the social tier to provision when SEED_CASDOOR_ONLY=1.
set -u
cd "$(dirname "$0")/../.."
fail=0; ok(){ echo "ok   - $*"; }; bad(){ echo "FAIL - $*"; fail=1; }
mk(){ make -n -s "$@" 2>&1; }
# grep -q on a captured string, never on a pipe: a pipe can SIGPIPE a found match into a failure
has(){ grep -q -- "$1" <<<"$2"; }

# (1)
for pat in '${PUBLIC_BIND_ADDR:-0.0.0.0}:${PUBLIC_HOST_PORT:-8088}:8080' \
           '${PUBLIC_BIND_ADDR:-0.0.0.0}:${PUBLIC_HTTPS_PORT:-8488}:8443' \
           '${PUBLIC_BIND_ADDR:-0.0.0.0}:${ANUBIS_HOST_PORT:-8923}:8923'; do
  grep -qF -- "${pat}" tests/stack/compose.local.yaml && ok "compose publishes ${pat}" || bad "compose lacks ${pat}"
done
o="$(mk stack-up ENV=local PUBLIC_BIND_ADDR=127.0.0.1)"; grep -qF "PUBLIC_BIND_ADDR='127.0.0.1'" <<<"${o}" \
  && ok "Makefile threads PUBLIC_BIND_ADDR to compose" || bad "Makefile does not thread PUBLIC_BIND_ADDR"

printf 'PUBLIC_BIND_ADDR := 127.0.0.1\n' > tests/stack/.local.mk
o="$(mk stack-up ENV=local)"; rm -f tests/stack/.local.mk
grep -qF "PUBLIC_BIND_ADDR='127.0.0.1'" <<<"${o}" && ok "tests/stack/.local.mk sets a knob with no command-line variable" || bad ".local.mk is not honoured"
git check-ignore -q tests/stack/.local.mk && ok ".local.mk is gitignored" || bad ".local.mk is not gitignored"

printf 'GAMES_SRC := /somewhere/hugmesh-games\n' > tests/stack/.local.mk
o="$(mk stack-up ENV=local)"; rm -f tests/stack/.local.mk
grep -qF "GAMES_SRC='/somewhere/hugmesh-games'" <<<"${o}" && ok "a GAMES_SRC set in .local.mk reaches compose (not only a command-line one)" || bad "GAMES_SRC from .local.mk is not threaded to compose"

# (2)
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
out="$(make -s stack-games-src-check GAMES=1 GAMES_SRC="${tmp}/none" 2>&1)"; rc=$?
{ [ "${rc}" -ne 0 ] && grep -q "GAMES_SRC" <<<"${out}"; } && ok "missing games checkout stops early and names GAMES_SRC" \
  || bad "missing games checkout not refused clearly (rc=${rc})"
mkdir -p "${tmp}/g/games-ui" "${tmp}/g/backend" "${tmp}/g/docker"
make -s stack-games-src-check GAMES=1 GAMES_SRC="${tmp}/g" >/dev/null 2>&1 && ok "present games checkout passes" || bad "present games checkout refused"
grep -qE '^stack-up:.*\$\(STACK_GAMES_DEP\)' Makefile && ok "stack-up depends on the games check" || bad "stack-up does not depend on the games check"

# (3)
for t in stack-up stack-build; do
  o="$(mk "${t}" ENV=local BUILD_NETWORK=host)"
  { has "gen-build-network.sh" "${o}" && has "compose.build-network.yaml" "${o}"; } \
    && ok "${t}: BUILD_NETWORK=host generates and includes the overlay" || bad "${t}: BUILD_NETWORK=host not wired"
  o="$(mk "${t}" ENV=local)"; has "build-network" "${o}" && bad "${t}: mentions the overlay without BUILD_NETWORK" || ok "${t}: unchanged without BUILD_NETWORK"
done
git check-ignore -q tests/stack/.compose.build-network.yaml && ok "overlay is gitignored" || bad "overlay is not gitignored"
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1 && command -v jq >/dev/null; then
  BUILD_NETWORK=bridge bash tests/stack/gen-build-network.sh "${tmp}/o.yaml" -f tests/stack/compose.local.yaml >/dev/null 2>&1 \
    && bad "generator accepted BUILD_NETWORK=bridge" || ok "generator rejects BUILD_NETWORK=bridge"
  if BUILD_NETWORK=host bash tests/stack/gen-build-network.sh "${tmp}/o.yaml" -f tests/stack/compose.local.yaml >/dev/null 2>&1; then
    n="$(grep -c 'network: host' "${tmp}/o.yaml")"; [ "${n}" -gt 10 ] && ok "generator wrote ${n} build networks" || bad "generator wrote only ${n}"
    ! grep -q "^  postgres:" "${tmp}/o.yaml" && ok "image-only services are left alone" || bad "an image-only service got a build block"
  else bad "generator failed on compose.local.yaml"; fi
else echo "skip - docker compose or jq absent: generator not exercised"; fi

# (4)
y="$(awk '/Stage 3: the platform accounts/{f=1} f&&/SEED_CASDOOR_ONLY.*!= "1"/{g=1} f&&g&&/provision_platform "\$\{u\}" matrix/{print "yes"; exit}' tests/stack/seed-e2e.sh)"
[ "${y}" = yes ] \
  && ok "seed skips social provisioning in SEED_CASDOOR_ONLY mode" || bad "seed still provisions social accounts in SEED_CASDOOR_ONLY mode"

exit "${fail}"

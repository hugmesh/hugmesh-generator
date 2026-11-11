#!/usr/bin/env bash
# test-stack-idp-exposure-live.sh — LIVE proof, on a throwaway compose project, that the
# local mesh's Casdoor is loopback-only and is moved off its factory-default admin
# password by the seed (NEW-15). The static/offline twin is
# tests/scripts/test-stack-idp-exposure.sh.
#
# THE DEFECT, as an attacker on the LAN sees it: `make stack-up` published Casdoor :8000
# on every host interface, and the built-in admin kept casbin/casdoor's public
# factory-default password through every `make stack-seed`, so POST /api/login with it
# from another machine returned an admin session for the mesh's identity provider.
#
# WHAT RUNS. The REAL tests/stack/compose.local.yaml (the Makefile's STACK_COMPOSE,
# which includes compose.real.yaml) is rendered with `docker compose config` from a
# scratch copy of tests/stack (dotfiles NOT copied, so no real .env is read; the DB
# passwords come from gen-stack-db-env.sh writing a scratch .env through a docker STUB,
# so no real container is ever asked). Then casdoor + casdoor-db are started from that
# render under a unique project name with ONE change, the published host port (the
# operator's own stack may hold 8000), and the REAL tests/stack/seed-e2e.sh is run
# against it (SEED_CASDOOR_ONLY=1). Asserted:
#   [render]  every identity-provider/homeserver publish renders host_ip 127.0.0.1 with
#             STACK_BIND_ADDR unset, and 0.0.0.0 when it is set (the opt-in works);
#   [door]    the live Casdoor answers on loopback and REFUSES the connection on a
#             non-loopback address of this host (the docker bridge gateway, and the
#             default-route source address when there is one): the LAN view;
#   [lan]     an admin login with the factory default from that address does not
#             succeed (on the defect it returns an admin session);
#   [seed]    the real seed exits 0, the factory default no longer signs in afterwards,
#             the generated CASDOOR_ADMIN_PASSWORD in the scratch file does, and a
#             second seed changes nothing (no move, still one admin password).
# IDPX_TREE=<checkout> runs the same assertions against another checkout's compose
# files and seed (e.g. an origin/main worktree, to watch them fail before the fix).
#
# SAFETY. Project name idpx-<pid>-<epoch>; any name that is not exactly that shape (or
# is hugmesh-local / hugmesh-real) is refused before the first `up`, the render is
# re-read to confirm the name compose will use, and the EXIT trap removes the project's
# containers, network and volume. Nothing else on the daemon is touched.
#
# Needs docker (daemon + compose v2), curl, jq, python3. Missing any of them exits 2:
# in the shell-suites "host docker" job that is a failure, never a skip.
# shellcheck disable=SC2015  # A && ok || bad is the assertion idiom this repo's guards use.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
TREE="$(cd "${IDPX_TREE:-${REPO}}" && pwd)"
TSTACK="${TREE}/tests/stack"
WAIT_S="${IDPX_WAIT_S:-240}"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P + 1)); }
bad() { echo "  FAIL $*"; F=$((F + 1)); }

for t in docker curl jq python3; do
  command -v "${t}" >/dev/null 2>&1 || { echo "FATAL: ${t} is required (this suite never skips)" >&2; exit 2; }
done
docker info >/dev/null 2>&1 || { echo "FATAL: no usable docker daemon" >&2; exit 2; }
docker compose version >/dev/null 2>&1 || { echo "FATAL: docker compose v2 is required" >&2; exit 2; }
[ -r "${TSTACK}/compose.local.yaml" ] && [ -r "${TSTACK}/seed-e2e.sh" ] \
  || { echo "FATAL: ${TSTACK} has no compose.local.yaml / seed-e2e.sh" >&2; exit 2; }

PROJECT="idpx-$$-$(date +%s)"
case "${PROJECT}" in
  hugmesh-local|hugmesh-real|hugmesh-*) echo "FATAL: refusing project name ${PROJECT}" >&2; exit 2 ;;
  idpx-[0-9]*-[0-9]*) ;;
  *) echo "FATAL: unexpected project name ${PROJECT}" >&2; exit 2 ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-stack-idp-exposure-live.XXXXXX")"
RUN="${WORK}/run.json"
cleanup() {
  if [ -s "${RUN}" ]; then
    docker compose -p "${PROJECT}" -f "${RUN}" down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT

echo "== NEW-15 live: Casdoor on a throwaway project (${PROJECT}), tree ${TREE} =="

# ── render the real compose entrypoint from a scratch copy ───────────────────
mkdir -p "${WORK}/render/stack" "${WORK}/bin"
for f in "${TSTACK}"/*; do cp -a "${f}" "${WORK}/render/stack/"; done   # the glob skips dotfiles
: > "${WORK}/render/stack/.mastodon.env"
cat > "${WORK}/bin/docker" <<'EOF'
#!/bin/sh
# docker STUB for gen-stack-db-env.sh: no volume exists, no container exists.
case "$1" in
  volume) echo "Error response from daemon: get ${3:-x}: no such volume" >&2; exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${WORK}/bin/docker"
STACK_DB_ENV_FILE="${WORK}/render/stack/.env" DOCKER="${WORK}/bin/docker" \
  bash "${WORK}/render/stack/gen-stack-db-env.sh" >/dev/null 2>"${WORK}/gen.err" \
  || { echo "FATAL: could not mint scratch DB passwords: $(head -2 "${WORK}/gen.err")" >&2; exit 2; }
render() { # render [VAR=value ...] -> JSON on stdout
  (cd "${WORK}/render" && env -u STACK_BIND_ADDR -u COMPOSE_PROJECT_NAME ROUTE_ACCESS_DB_PASSWORD=idpx "$@" \
     docker compose -p "${PROJECT}" -f stack/compose.local.yaml \
       --profile social --profile brandb --profile phpbb --profile akkoma \
       config --format json 2>"${WORK}/render.err")
}
render > "${WORK}/default.json" \
  || { echo "FATAL: docker compose config failed: $(grep -v 'is not set' "${WORK}/render.err" | head -3)" >&2; exit 2; }
render STACK_BIND_ADDR=0.0.0.0 > "${WORK}/optin.json" || { echo "FATAL: opt-in render failed" >&2; exit 2; }

echo "-- [render] identity provider / homeserver publishes, as compose will run them --"
for svc in casdoor casdoor-brandb tuwunel mastodon-web mastodon-streaming akkoma phpbb; do
  d="$(jq -r --arg s "${svc}" '[.services[$s].ports[]? | (.host_ip // "")] | if length == 0 then "<none>" else join(",") end' "${WORK}/default.json")"
  o="$(jq -r --arg s "${svc}" '[.services[$s].ports[]? | (.host_ip // "")] | if length == 0 then "<none>" else join(",") end' "${WORK}/optin.json")"
  [ "${d}" = "127.0.0.1" ] && ok "${svc}: host_ip 127.0.0.1 by default" \
    || bad "${svc}: host_ip '${d}' by default (empty = every interface)"
  [ "${o}" = "0.0.0.0" ] && ok "${svc}: STACK_BIND_ADDR=0.0.0.0 opts into every interface" \
    || bad "${svc}: STACK_BIND_ADDR=0.0.0.0 rendered host_ip '${o}' (the opt-in does not reach it)"
done

# ── bring up casdoor + casdoor-db from the render, on a free port ────────────
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
jq --arg p "${PORT}" --arg proj "${PROJECT}" '{
    name: $proj,
    services: {
      casdoor: (.services.casdoor | .ports |= map(.published = $p)),
      "casdoor-db": .services["casdoor-db"]
    },
    volumes: { "casdoor-pg": .volumes["casdoor-pg"] },
    networks: { default: .networks.default }
  }' "${WORK}/default.json" > "${RUN}"
name="$(docker compose -p "${PROJECT}" -f "${RUN}" config --format json 2>/dev/null | jq -r '.name // empty')"
vol="$(jq -r '.volumes["casdoor-pg"].name // empty' "${RUN}")"
cn="$(jq -r '[.services[] | .container_name // empty] | join(",")' "${RUN}")"
if [ "${name}" != "${PROJECT}" ] || [ "${vol}" != "${PROJECT}_casdoor-pg" ] || [ -n "${cn}" ]; then
  echo "FATAL: the run file is not isolated (name='${name}' volume='${vol}' container_name='${cn}'); nothing started" >&2
  exit 2
fi
ok "run file isolated: project ${PROJECT}, volume ${vol}, no fixed container name; only the host port changed (${PORT})"
if ! docker compose -p "${PROJECT}" -f "${RUN}" up -d casdoor >"${WORK}/up.log" 2>&1; then
  echo "FATAL: could not start the throwaway Casdoor: $(tail -3 "${WORK}/up.log")" >&2
  exit 2
fi
BASE="http://127.0.0.1:${PORT}"
t=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${BASE}/api/get-account" 2>/dev/null)" = 200 ]; do
  [ "${t}" -ge "${WAIT_S}" ] && { echo "FATAL: Casdoor did not answer on ${BASE} within ${WAIT_S}s: $(docker compose -p "${PROJECT}" -f "${RUN}" logs --tail 5 casdoor 2>&1 | tail -5)" >&2; exit 2; }
  sleep 3; t=$((t + 3))
done
echo "  (Casdoor answering on ${BASE} after ${t}s)"

login() { # login <base> <password> -> prints "ok" | "refused" | "unreachable"
  local body
  body="$(IDPX_PW="$2" jq -nc '{application:"app-built-in",organization:"built-in",username:"admin",password:env.IDPX_PW,type:"login",autoSignin:true}' \
          | curl -s --max-time 10 "$1/api/login" -H 'content-type: application/json' --data-binary @- 2>/dev/null)" \
    || { echo unreachable; return 0; }
  if printf '%s' "${body}" | jq -e '.status == "ok"' >/dev/null 2>&1; then echo ok; else echo refused; fi
}
FACTORY="123"   # casbin/casdoor's public factory default for the built-in admin

echo "-- [door] who can reach it --"
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${BASE}/" 2>/dev/null)" = 200 ] \
  && ok "loopback ${BASE} answers" || bad "loopback ${BASE} does not answer"
addrs=()
gw="$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null | awk '{print $1}')"
[ -n "${gw}" ] && addrs+=("${gw}")
if command -v ip >/dev/null 2>&1; then
  src="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
  [ -n "${src}" ] && [ "${src}" != "${gw}" ] && addrs+=("${src}")
fi
[ "${#addrs[@]}" -ge 1 ] && ok "non-loopback address(es) of this host to probe: ${addrs[*]}" \
  || bad "found no non-loopback address of this host to probe from"
for a in "${addrs[@]}"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${a}:${PORT}/" 2>/dev/null)"
  [ "${code}" = 000 ] && ok "${a}:${PORT} refuses the connection (not published there)" \
    || bad "${a}:${PORT} answers HTTP ${code}: Casdoor is published on a non-loopback interface"
done

echo "-- [lan] the attacker's request, from a non-loopback address, before any seed --"
for a in "${addrs[@]}"; do
  r="$(login "http://${a}:${PORT}" "${FACTORY}")"
  [ "${r}" != ok ] && ok "admin login with the factory default via ${a}: ${r}" \
    || bad "admin login with the factory default via ${a} returned an ADMIN SESSION (LAN takeover)"
done
[ "$(login "${BASE}" "${FACTORY}")" = ok ] && ok "precondition: a fresh Casdoor's admin is on the factory default (loopback)" \
  || bad "precondition: the factory default does not sign in on a fresh volume; this run proves nothing about the move"

echo "-- [seed] the real seed-e2e.sh against it --"
ADMIN_ENV="${WORK}/admin.env"
seed() { # seed <log>
  env -u CASDOOR_ADMIN_PASS CASDOOR_URL="${BASE}" FRONT_DOOR="${BASE}" SEED_CASDOOR_ONLY=1 \
      SEED_COMPLETE_REGISTRATION=0 SEED_WAIT_S=60 CASDOOR_ADMIN_ENV_FILE="${ADMIN_ENV}" \
      E2E_CREDENTIALS_FILE="${WORK}/e2e-credentials" SEED_WORKDIR="${WORK}/seedwork" \
      timeout 600 bash "${TSTACK}/seed-e2e.sh" >"$1" 2>&1
}
seed "${WORK}/seed1.log"; rc=$?
[ "${rc}" -eq 0 ] && ok "seed exits 0" || bad "seed exited ${rc}: $(tail -3 "${WORK}/seed1.log" | tr '\n' '|')"
grep -q 'moved off the factory default' "${WORK}/seed1.log" \
  && ok "the seed says it moved the admin off the factory default" \
  || bad "the seed never moved the admin off the factory default"
r="$(login "${BASE}" "${FACTORY}")"
[ "${r}" = refused ] && ok "after the seed the factory default is REFUSED" \
  || bad "after the seed the factory default login is '${r}' (still the admin's password)"
GENPW="$(sed -n 's/^CASDOOR_ADMIN_PASSWORD=//p' "${ADMIN_ENV}" 2>/dev/null | tail -1)"
if [ -n "${GENPW}" ]; then
  [ "$(login "${BASE}" "${GENPW}")" = ok ] && ok "the generated CASDOOR_ADMIN_PASSWORD signs in" \
    || bad "the generated CASDOOR_ADMIN_PASSWORD does not sign in"
else
  bad "the seed left no CASDOOR_ADMIN_PASSWORD in ${ADMIN_ENV##*/}"
fi
seed "${WORK}/seed2.log"; rc=$?
[ "${rc}" -eq 0 ] && ! grep -q 'moving it onto' "${WORK}/seed2.log" \
  && ok "a second seed exits 0 and moves nothing (already converged)" \
  || bad "second seed: rc=${rc}, moved again: $(grep -c 'moving it onto' "${WORK}/seed2.log" || true)"
if [ -n "${GENPW}" ]; then
  grep -F -q -- "${GENPW}" "${WORK}/seed1.log" "${WORK}/seed2.log" \
    && bad "the generated admin password appears in the seed output" \
    || ok "the generated admin password never appears in the seed output"
fi

echo
echo "== NEW-15 live: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

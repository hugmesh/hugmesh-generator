#!/usr/bin/env bash
# test-tls-front.sh — unit test for the local stack's HTTPS front door.
#
# REQUIREMENT: https://localhost:${PUBLIC_HTTPS_PORT:-8488} must serve the
# IDENTICAL platform as the plain http://localhost:8088 door, under ENV=test
# AND ENV=prod, off per-machine (gitignored) TLS material. This proves the
# load-bearing wiring WITHOUT docker:
#   1) compose has the https-front service, publishing the knobbed host port
#      onto the SAME container port nginx actually listens on (derived, not
#      assumed), mounting the committed conf + the per-machine cert dir at the
#      SAME path the conf's ssl_certificate* directives read from;
#   2) the terminator proxies to the fe-gateway compose DNS name and does NOT
#      send HSTS (per-HOST scope would force-upgrade every other localhost
#      port: 8088, 8000, 8008, ...);
#   3) SNAP_BFF_URL's compose default is EMPTY (same-origin) — the old
#      absolute http://localhost:8088 default made every login POST from the
#      https door browser-BLOCKED active mixed content;
#   4) Makefile: stack-up AND stack-build mint certs first (stack-certs),
#      PUBLIC_HTTPS_PORT is a threaded knob, and the mint dir is gitignored
#      (PRIVATE KEYS - the operator may trust this CA in a browser);
#   5) functional: gen-certs.sh really mints a localhost-SAN'd leaf whose key
#      matches, chained to the CA (openssl; skipped if openssl is absent).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
COMPOSE="${HERE}/compose.local.yaml"
CONF="${HERE}/tls-front/default.conf"
MK="${REPO}/Makefile"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== HTTPS front door (tls-front) unit test =="

echo "-- 1) compose service wiring --"
# The https-front service block, isolated so greps can't match other services.
BLOCK="$(awk '/^  hugmesh-https-front:/{f=1} f&&/^  [a-zA-Z]/&&!/^  hugmesh-https-front:/{exit} f{print}' "${COMPOSE}")"
[ -n "${BLOCK}" ] && ok "compose has a hugmesh-https-front service" \
                  || bad "compose is missing the hugmesh-https-front service"

# Host publish: knobbed port, default 8488 (NOT 8443 - commonly taken on dev
# boxes). Derive the CONTAINER port so we can cross-check nginx below.
PORTLINE="$(printf '%s\n' "${BLOCK}" | grep -E 'PUBLIC_HTTPS_PORT' || true)"
printf '%s' "${PORTLINE}" | grep 'PUBLIC_HTTPS_PORT:-8488' >/dev/null \
  && ok "publishes \${PUBLIC_HTTPS_PORT:-8488} (default 8488)" \
  || bad "host publish is not \${PUBLIC_HTTPS_PORT:-8488}: '${PORTLINE}'"
CONTAINER_PORT="$(printf '%s' "${PORTLINE}" | sed -E 's/.*}:([0-9]+)".*/\1/')"
[ -n "${CONTAINER_PORT}" ] && ok "container port derived: ${CONTAINER_PORT}" \
                           || bad "could not derive the container port from '${PORTLINE}'"

# Mounts: the committed conf, and the per-machine cert dir. Derive the mount
# TARGET so we can cross-check the conf's ssl_certificate paths against it.
printf '%s\n' "${BLOCK}" | grep './tls-front/default.conf:/etc/nginx/conf.d/default.conf:ro' >/dev/null \
  && ok "mounts the committed tls-front/default.conf" \
  || bad "does not mount tls-front/default.conf into conf.d"
CERTMOUNT="$(printf '%s\n' "${BLOCK}" | grep -E '\./\.tls-front:' | sed -E 's/.*\.tls-front:([^:]+):ro.*/\1/' || true)"
[ -n "${CERTMOUNT}" ] && ok "mounts per-machine ./.tls-front certs at ${CERTMOUNT} (ro)" \
                      || bad "does not mount ./.tls-front read-only"

printf '%s\n' "${BLOCK}" | grep 'hugmesh-fe-gateway' >/dev/null \
  && ok "depends on the fe-gateway" || bad "no fe-gateway dependency"
# Always-on: an accidental `profiles:` entry would silently drop the https
# door from plain `make stack-up` - exactly the "works in test and prod" ask.
printf '%s\n' "${BLOCK}" | grep 'profiles:' >/dev/null \
  && bad "https-front is profile-gated - it must be unconditional" \
  || ok "unconditional (no compose profile)"

echo "-- 2) nginx terminator conf --"
# The door proxies to the fe-gateway on 8080 through a VARIABLE, and the variable
# is the point: nginx resolves a LITERAL proxy_pass hostname exactly once, when
# the config loads, and then caches that address forever — so recreating the
# fe-gateway container black-holes the door until nginx is reloaded. This guard
# used to pin the literal spelling `proxy_pass http://hugmesh-fe-gateway:8080`,
# which the conf correctly stopped using on 2026-08-20; it then read as "the door
# does not proxy to the fe-gateway at all". Assert the two halves that actually
# carry the protection instead, so neither the target nor the re-resolution can
# be dropped without this going red.
grep -qE '^[[:space:]]*set +\$fe_gateway +hugmesh-fe-gateway;' "${CONF}" \
  && ok "names hugmesh-fe-gateway as the upstream (via \$fe_gateway)" \
  || bad "conf no longer names hugmesh-fe-gateway as the upstream"
grep -qE 'proxy_pass +http://\$fe_gateway:8080' "${CONF}" \
  && ok "proxies to \$fe_gateway:8080 — a VARIABLE, so nginx re-resolves it per request" \
  || bad "proxy_pass does not go through \$fe_gateway:8080 — a literal hostname is resolved once at load and cached forever, so a recreated gateway black-holes the door"
grep -qE "listen +${CONTAINER_PORT:-NEVER} +ssl" "${CONF}" \
  && ok "nginx listens on the SAME port compose publishes (${CONTAINER_PORT})" \
  || bad "nginx listen port != compose container port (${CONTAINER_PORT})"
for f in fullchain.crt server.key; do
  grep -q "${CERTMOUNT:-NEVER}/${f}" "${CONF}" \
    && ok "ssl material read from the compose mount target (${CERTMOUNT}/${f})" \
    || bad "conf does not read ${f} from the compose mount target ${CERTMOUNT}"
done
grep -q 'X-Forwarded-Proto https' "${CONF}" \
  && ok "sets X-Forwarded-Proto https" || bad "missing X-Forwarded-Proto https"
# HSTS, in two halves. The old single check matched ANY live mention of
# Strict-Transport-Security and so could not tell SENDING it from STRIPPING it —
# it fired on the conf's own `proxy_hide_header Strict-Transport-Security`, which
# is the protection, not the defect. Comments explaining the stance are fine
# either way; only non-comment lines are read.
LIVE="$(grep -viE '^[[:space:]]*#' "${CONF}")"
printf '%s\n' "${LIVE}" | grep -iE 'add_header[[:space:]]+"?Strict-Transport-Security' >/dev/null \
  && bad "conf SENDS HSTS — it is scoped per-HOST, not per-port, so one header force-upgrades every other plain localhost door (8088 front door, 8000 Casdoor, ...)" \
  || ok "conf never sends HSTS (deliberate: HSTS is per-host, not per-port)"
printf '%s\n' "${LIVE}" | grep -iE 'proxy_hide_header[[:space:]]+Strict-Transport-Security' >/dev/null \
  && ok "conf STRIPS any upstream HSTS — the gateway's own header cannot pin localhost" \
  || bad "conf no longer strips upstream Strict-Transport-Security: a gateway that sends HSTS would pin localhost in the browser, and removing the header afterwards does NOT un-pin it (chrome://net-internals/#hsts is the only cure)"

echo "-- 3) SNAP_BFF_URL same-origin default (mixed-content guard) --"
BFFLINE="$(grep -E '^ +SNAP_BFF_URL:' "${COMPOSE}" || true)"
printf '%s' "${BFFLINE}" | grep -E 'SNAP_BFF_URL: \$\{SNAP_BFF_URL:-\}' >/dev/null \
  && ok "SNAP_BFF_URL defaults EMPTY (same-origin on both doors)" \
  || bad "SNAP_BFF_URL default is not empty: '${BFFLINE}' - an absolute http:// default is browser-BLOCKED mixed content on the https door"

echo "-- 4) Makefile + gitignore --"
grep -qE '^stack-certs:' "${MK}" && ok "stack-certs target exists" || bad "no stack-certs target"
grep -qE '^stack-up: .*stack-certs' "${MK}" \
  && ok "stack-up depends on stack-certs" || bad "stack-up does not mint certs first"
grep -qE '^stack-build: .*stack-certs' "${MK}" \
  && ok "stack-build depends on stack-certs" || bad "stack-build does not mint certs first"
grep -qE "PUBLIC_HTTPS_PORT \?= 8488" "${MK}" \
  && ok "PUBLIC_HTTPS_PORT knob (default 8488)" || bad "no PUBLIC_HTTPS_PORT knob"
grep -qE "PUBLIC_HTTPS_PORT='\\\$\(PUBLIC_HTTPS_PORT\)'" "${MK}" \
  && ok "PUBLIC_HTTPS_PORT threaded into STACK_ENV" || bad "knob not threaded into STACK_ENV"
grep -qE 'gen-certs\.sh.*STACK_TLS_DIR|bash tests/stack/gen-certs\.sh' "${MK}" \
  && ok "stack-certs mints via gen-certs.sh" || bad "stack-certs does not call gen-certs.sh"
grep -qE '^tests/stack/\.tls-front/' "${REPO}/.gitignore" \
  && ok ".tls-front/ is gitignored (private keys)" || bad "tests/stack/.tls-front/ NOT gitignored - keys would be committed"

echo "-- 5) functional mint (gen-certs.sh) --"
if command -v openssl >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT
  if bash "${HERE}/gen-certs.sh" "${TMP}/mint" >/dev/null 2>&1; then
    ok "gen-certs.sh mints into an explicit output dir"
    SAN="$(openssl x509 -in "${TMP}/mint/server.crt" -noout -ext subjectAltName 2>/dev/null || true)"
    printf '%s' "${SAN}" | grep 'DNS:localhost' >/dev/null \
      && ok "leaf SAN covers localhost" || bad "leaf SAN missing DNS:localhost: ${SAN}"
    printf '%s' "${SAN}" | grep '127.0.0.1' >/dev/null \
      && ok "leaf SAN covers 127.0.0.1" || bad "leaf SAN missing 127.0.0.1"
    # Key <-> cert agreement, and the chain the conf serves must verify.
    CMOD="$(openssl x509 -in "${TMP}/mint/server.crt" -noout -modulus 2>/dev/null)"
    KMOD="$(openssl rsa -in "${TMP}/mint/server.key" -noout -modulus 2>/dev/null)"
    [ -n "${CMOD}" ] && [ "${CMOD}" = "${KMOD}" ] \
      && ok "server.key matches server.crt" || bad "server.key does NOT match server.crt"
    openssl verify -CAfile "${TMP}/mint/ca.crt" "${TMP}/mint/server.crt" >/dev/null 2>&1 \
      && ok "leaf verifies against the minted CA" || bad "leaf does not chain to the minted CA"
    grep -c 'BEGIN CERTIFICATE' "${TMP}/mint/fullchain.crt" | grep -x 2 >/dev/null \
      && ok "fullchain.crt = leaf + CA (2 certs)" || bad "fullchain.crt is not leaf+CA"
  else
    bad "gen-certs.sh failed to mint into ${TMP}/mint"
  fi
else
  echo "  SKIP openssl not available - functional mint not exercised"
fi

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]

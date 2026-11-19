#!/usr/bin/env bash
# lan-bind-preflight.sh — a LAN bind is refused while any Casdoor still has its factory admin.
# (hugmesh-generator#1034)
#
# `make stack-up STACK_BIND_ADDR=0.0.0.0` is the documented opt-in that publishes Casdoor (and the
# per-domain Casdoors the Studio starts on :8001+) on every interface. A fresh Casdoor's built-in admin
# signs in with upstream's public factory password, and `make stack-seed` is what moves it (only on the
# Casdoors it knows about). Nothing checked that before the bind opened, so the opt-in could put an
# identity provider with a publicly known admin login on the LAN.
#
# This runs BEFORE `up`. STACK_BIND_ADDR unset or loopback: exits 0 at once and touches nothing. Any
# other value: every Casdoor this checkout can start is probed ON LOOPBACK (where the running containers
# still listen) with the factory admin login, and the bind is refused when
#   - the factory login is ACCEPTED   (that Casdoor still has the factory admin: named),
#   - the probe gets no answer        (nothing proves the admin was moved: named), or
#   - the answer is the sign-in throttle (a refusal that says nothing about the password: named).
# The way through is the order the message prints: bring the stack up on loopback, `make stack-seed`
# (moves the admin on :8000 and on every per-domain Casdoor), then re-run with the bind.
#
# Which Casdoors: LAN_GUARD_CASDOOR_URLS (space separated; the override tests use), else
#   http://127.0.0.1:8000, every host port the Studio overlay tests/stack/.compose.own-domains.yaml
#   publishes (container :8000), and :8001 when BRAND_B is set.
#
# The factory value is public upstream knowledge, not a secret; it is still sent on stdin and never
# printed. Exit 0 safe (or loopback), 1 refused, 2 unusable environment.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIND="${STACK_BIND_ADDR:-127.0.0.1}"
FACTORY="${CASDOOR_BOOTSTRAP_PASSWORD:-123}"
ADMIN_USER="${CASDOOR_ADMIN_USER:-admin}"

case "${BIND}" in
  127.*|localhost|::1|\[::1\]) exit 0 ;;
esac

for t in curl jq; do
  command -v "${t}" >/dev/null 2>&1 || { echo "lan-bind-preflight: ${t} is required to prove the admin was moved" >&2; exit 2; }
done

urls=()
if [ -n "${LAN_GUARD_CASDOOR_URLS:-}" ]; then
  # shellcheck disable=SC2206  # a space-separated list by contract
  urls=(${LAN_GUARD_CASDOOR_URLS})
else
  urls+=("http://127.0.0.1:8000")
  overlay="${HERE}/.compose.own-domains.yaml"
  if [ -r "${overlay}" ]; then
    while IFS= read -r p; do [ -n "${p}" ] && urls+=("http://127.0.0.1:${p}"); done \
      < <(sed -n 's/.*:\([0-9][0-9]*\):8000".*/\1/p' "${overlay}" | sort -un)
  fi
  [ -n "${BRAND_B:-}" ] && [ "${BRAND_B}" != 0 ] && urls+=("http://127.0.0.1:8001")
  # de-duplicate, keep order
  mapfile -t urls < <(printf '%s\n' "${urls[@]}" | awk '!seen[$0]++')
fi

echo "lan-bind-preflight: STACK_BIND_ADDR=${BIND} is not loopback; probing the factory admin login on: ${urls[*]}" >&2
[ "${LAN_GUARD_LIST_ONLY:-0}" = 1 ] && exit 0   # tests: show which Casdoors would be probed, send nothing

problems=()
for u in "${urls[@]}"; do
  body="$(ADMIN_USER="${ADMIN_USER}" FACTORY="${FACTORY}" jq -nc \
            '{application:"app-built-in",organization:"built-in",username:env.ADMIN_USER,password:env.FACTORY,type:"login",autoSignin:true}' \
          | curl -s --max-time 10 "${u}/api/login" -H 'content-type: application/json' --data-binary @- 2>/dev/null)" || body=""
  if [ -z "${body}" ] || ! printf '%s' "${body}" | jq -e 'type == "object" and has("status")' >/dev/null 2>&1; then
    problems+=("${u}: no usable answer, so nothing proves its admin was moved (is it up? bring the stack up on loopback first)")
  elif printf '%s' "${body}" | jq -e '.status == "ok"' >/dev/null 2>&1; then
    problems+=("${u}: STILL ACCEPTS THE FACTORY ADMIN LOGIN")
  elif msg="$(printf '%s' "${body}" | jq -r '.msg // ""')"; [[ "${msg,,}" == *"too many times"* ]]; then
    problems+=("${u}: its sign-in throttle refused the probe, which says nothing about the password (wait, then retry)")
  fi
done

if [ "${#problems[@]}" -gt 0 ]; then
  echo "lan-bind-preflight: REFUSING STACK_BIND_ADDR=${BIND}: ${#problems[@]} of ${#urls[@]} Casdoor(s) cannot be shown to have left the factory admin." >&2
  for p in "${problems[@]}"; do echo "  - ${p}" >&2; done
  cat >&2 <<'MSG'
  Casdoor ships with a public admin login, so a LAN-reachable one hands the identity provider to anyone on the network.
  The order that works:
    1. make stack-up                       (loopback only)
    2. make stack-seed                     (moves the admin on :8000 and every per-domain Casdoor to a generated password)
    3. make stack-up STACK_BIND_ADDR=<addr>
MSG
  exit 1
fi
echo "lan-bind-preflight: STACK_BIND_ADDR=${BIND}: every Casdoor (${#urls[@]}) refused the factory admin login; the bind may open."
exit 0

#!/usr/bin/env bash
# test-password-reset-front-door.sh
#
# THE ANONYMOUS FORGOT-PASSWORD PATH, END TO END THROUGH THE FRONT DOOR.
#
# user-bff owns /bff/password-reset/{request,confirm} and permitAll's exactly those
# two. Reaching them needs FOUR independent things to be true, and each was found
# false at least once:
#
#   1. a gateway ROUTE, in the cluster table AND the compose table — without one the
#      request falls through the /bff/** catch-all to ADMIN-bff, which implements
#      neither. (Exactly the /bff/register/complete finding, in the other direction.)
#   2. that route declared BEFORE the catch-all — Spring Cloud Gateway matches in
#      DECLARED ORDER, so a correct route underneath /bff/** never runs.
#   3. the gateway's PUBLIC_PATHS floor opened, or anyExchange().authenticated()
#      401s the anonymous caller before the route runs. That lives in the
#      hugmesh-gateway repo and is NOT checkable from here — see section 3.
#   4. casdoor.password-reset.enabled, which is deliberately default-OFF and needs
#      Casdoor SMTP. This guard does NOT require it to be on; it requires the SWITCH
#      to EXIST, because a dark surface with no reachable switch reads as broken.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
CLUSTER="${REPO}/specs/cluster/apps/20-gateway-fe.yaml"
COMPOSE_ROUTES="${REPO}/tests/stack/gateway-routes/fe/application-routes.yml"
COMPOSE="${REPO}/tests/stack/compose.local.yaml"
USERBFF="${REPO}/specs/cluster/manifests/user-bff-api/deployment.yaml"

P=0; F=0
ok()  { echo "  ok   $*"; P=$((P + 1)); }
bad() { echo "  FAIL $*"; F=$((F + 1)); }

echo "== password-reset front door =="

# ── 1. the CLUSTER table: routed to user-bff, and ABOVE the catch-all ────────
echo "-- 1. cluster route table --"
if [ ! -f "${CLUSTER}" ]; then
  bad "${CLUSTER#"${REPO}/"} is missing — nothing asserted"
else
  CLUSTER="${CLUSTER}" python3 - <<'PY'
import os, re, sys
p = os.environ["CLUSTER"]
text = open(p, encoding="utf-8").read()
# Strip comments first: a path named only in PROSE must not satisfy a check that a
# ROUTE exists. This file is heavily commented and names these very paths in them.
body = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))

routes = re.findall(r'- id:\s*(\S+)\s*\n\s*uri:\s*(\S+)\s*\n\s*path:\s*(\S+)', body)
if len(routes) < 10:
    print("       only %d route(s) parsed — expected 10+; the parser no longer matches"
          " this file's shape, so its verdict would be meaningless" % len(routes))
    sys.exit(1)

order = {}
catchall = None
for i, (rid, uri, path) in enumerate(routes):
    order.setdefault(path, (i, uri, rid))
    if path == "/bff/**":
        catchall = i

problems = []
for want in ("/bff/password-reset/request", "/bff/password-reset/confirm"):
    hit = order.get(want)
    if not hit:
        problems.append("no route for %s — it falls through /bff/** to admin-bff,"
                        " which does not implement it" % want)
        continue
    i, uri, rid = hit
    if "user-bff" not in uri:
        problems.append("%s routes to %s (id=%s) — user-bff owns it" % (want, uri, rid))
    elif catchall is not None and i > catchall:
        problems.append("%s is declared AFTER the /bff/** catch-all (index %d > %d)"
                        " — Spring Cloud Gateway matches in DECLARED ORDER, so this"
                        " route never runs" % (want, i, catchall))

if problems:
    for pr in problems:
        print("       " + pr)
    sys.exit(1)
print("       %d routes parsed" % len(routes))
PY
  rc1=$?
  if [ "${rc1}" -eq 0 ]; then
    ok "both legs route to user-bff, above the /bff/** catch-all"
  else
    bad "cluster route table (detail above)"
  fi
fi

# ── 2. the COMPOSE table: same two paths, on the user-bff predicate ──────────
echo "-- 2. compose route table --"
if [ ! -f "${COMPOSE_ROUTES}" ]; then
  bad "${COMPOSE_ROUTES#"${REPO}/"} is missing — nothing asserted"
else
  # Comment-stripped for the same reason as above.
  pred="$(grep -v '^\s*#' "${COMPOSE_ROUTES}" | grep -E '^\s*- Path=.*(/bff/login|/bff/password-reset)' || true)"
  if [ -z "${pred}" ]; then
    bad "no /bff/login or /bff/password-reset Path predicate found in the compose
       table — the parser no longer matches its shape, so nothing was checked"
  else
    miss=""
    for want in /bff/password-reset/request /bff/password-reset/confirm; do
      printf '%s' "${pred}" | grep -F "${want}" >/dev/null || miss="${miss} ${want}"
    done
    if [ -n "${miss}" ]; then
      bad "compose route table does not carry:${miss}
       => they fall through to the /bff/** admin-bff catch-all, which implements
          neither. Compose and the cluster must agree; docs/KIND-SSO-E2E-FINDINGS.md
          is a list of the times they did not."
    else
      ok "both legs are on the user-bff Path predicate in the compose table"
    fi
  fi
fi

# ── 3. the switch EXISTS in both environments ───────────────────────────────
# NOT "is on": default-off is the deliberate design (permitAll + credential-writing,
# and undeliverable without Casdoor SMTP). What must not happen is a dark surface
# with no reachable switch, which is indistinguishable from a broken one.
echo "-- 3. the enable switch exists (not that it is on) --"
missing=""
[ -f "${USERBFF}" ] && grep -q 'CASDOOR_PASSWORD_RESET_ENABLED' "${USERBFF}" || missing="${missing} cluster(user-bff deployment)"
[ -f "${COMPOSE}" ] && grep -q 'CASDOOR_PASSWORD_RESET_ENABLED' "${COMPOSE}" || missing="${missing} compose"
if [ -n "${missing}" ]; then
  bad "casdoor.password-reset.enabled has no env var in:${missing}
       => the property exists in the code and defaults to false, so with no env var
          anywhere there is NO supported way to turn the feature on."
else
  ok "CASDOOR_PASSWORD_RESET_ENABLED is present in both the cluster deployment and compose"
fi

# ── 4. the cross-repo half, stated rather than silently skipped ──────────────
echo "-- 4. the gateway PUBLIC_PATHS floor (cross-repo) --"
GW="${REPO}/.stack-src/hugmesh-gateway/src/main/java/net/hugmesh/gateway/config/SecurityConfig.java"
if [ ! -f "${GW}" ]; then
  echo "  note the hugmesh-gateway checkout is absent, so the PUBLIC_PATHS floor could"
  echo "       not be checked from here. It is the THIRD of the four things this path"
  echo "       needs: without /bff/password-reset/{request,confirm} in PUBLIC_PATHS the"
  echo "       gateway 401s the anonymous caller before any route runs. Covered by"
  echo "       SecurityConfigPathGateSliceTest in that repo (hugmesh-gateway#21)."
else
  n=0
  for want in /bff/password-reset/request /bff/password-reset/confirm; do
    grep -F "\"${want}\"" "${GW}" >/dev/null && n=$((n + 1))
  done
  if [ "${n}" -ne 2 ]; then
    bad "the vendored hugmesh-gateway checkout's PUBLIC_PATHS names ${n}/2 reset legs
       — the anonymous caller is 401'd before the route runs. (This checkout may be
       stale; the authority is the hugmesh-gateway repo.)"
  else
    ok "the vendored gateway checkout's PUBLIC_PATHS names both reset legs"
  fi
fi

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
exit 0

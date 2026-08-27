#!/usr/bin/env bash
# test-password-reset-front-door.sh — the anonymous forgot-password legs must be
# reachable, and reachable IDENTICALLY, in every lane that has a front door.
#
# WHY THIS EXISTS. Password RESET did not exist anywhere in this platform: the only
# credential-write surface was the AUTHENTICATED profile change, which needs a live
# session and the CURRENT password — three things a locked-out user cannot supply.
# The new surface is user-bff's POST /bff/password-reset/{request,confirm}.
#
# Reaching it from a browser needs FOUR independent files to agree, and every one of
# them fails SILENTLY on its own:
#
#   1. specs/cluster/apps/20-gateway-fe.yaml        — the cluster/device ROUTE
#   2. tests/stack/gateway-routes/fe/application-routes.yml — the compose ROUTE
#   3. manifests/route-access/initdb/20-schema.sql  — a PUBLIC row per exact path
#   4. hugmesh-gateway SecurityConfig.PUBLIC_PATHS  — NOT IN THIS REPO (see below)
#
# Miss the route and the caller gets a 404 from whichever service the /bff/**
# catch-all happens to hit. Miss the PUBLIC row and the gateway's route-access
# filter DENIES. Miss PUBLIC_PATHS and the gateway's coarse
# anyExchange().authenticated() floor 401s BEFORE route-access is consulted. In all
# three cases every unit test in every repo stays green — this is the exact shape of
# the compose/cluster drift docs/KIND-SSO-E2E-FINDINGS.md keeps recording, most
# recently /bff/register/complete routing to a service that never implemented it.
#
# WHAT THIS GATE DOES **NOT** COVER, stated out loud rather than implied:
#
#   * LAYER 4 IS OUT OF REPO. hugmesh-gateway is a different repository, so this
#     script cannot check PUBLIC_PATHS. It is asserted here only as a comment in
#     20-schema.sql, and it is the one layer a reader must verify by hand.
#   * NO LIVE PROBE. Nothing is executed against a running gateway; this compares
#     committed text. A curl through the real front door is what would settle it.
#   * ROUTABILITY, NOT DELIVERY. Casdoor mails the reset code over SMTP, which is
#     absent-by-default platform-wide. Every assertion below can pass on a mesh
#     where no reset email is ever sent.
#
# Offline: bash + grep only. No node, no cluster, no network. Read-only.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

CLUSTER_FE="${REPO}/specs/cluster/apps/20-gateway-fe.yaml"
COMPOSE_FE="${REPO}/tests/stack/gateway-routes/fe/application-routes.yml"
SEED="${REPO}/specs/cluster/manifests/route-access/initdb/20-schema.sql"

PATHS=(/bff/password-reset/request /bff/password-reset/confirm)

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

for f in "${CLUSTER_FE}" "${COMPOSE_FE}" "${SEED}"; do
  [[ -r "${f}" ]] || { echo "ABORT: unreadable ${f}"; exit 2; }
done

# ── strip comments FIRST ─────────────────────────────────────────────────────
# Every file here EXPLAINS these paths in prose right next to where it declares
# them, so a naive grep matches the explanation and passes even when the
# declaration is gone. Comment-token inversion has produced false greens in this
# repo repeatedly; the whole gate runs against comment-stripped copies.
strip_yaml() { sed 's/#.*$//' "$1"; }
strip_sql()  { sed 's/--.*$//' "$1"; }

# ── the three checks, as functions so the negative controls can re-run them ──

# The CLUSTER route table declares each exact path (not a /** subtree, which would
# swallow every future sibling — the /bff/register/** mistake).
check_cluster_route() {
  local body; body="$(strip_yaml "$1")"
  # SUBTREE FIRST. Widening an exact path to /** ALSO removes the exact path, so a
  # missing-path check placed first would report the milder defect and the subtree
  # branch would be unreachable — which is exactly what the negative control below
  # caught on this script's first run.
  grep -Fq "path: /bff/password-reset/**" <<<"${body}" && return 2
  local p
  for p in "${PATHS[@]}"; do
    grep -Fq "path: ${p}" <<<"${body}" || return 1
  done
  return 0
}

# The COMPOSE route predicate lists each exact path on its Path= line.
check_compose_route() {
  local body; body="$(strip_yaml "$1")"
  local line
  line="$(grep -F -- '- Path=/bff/login' <<<"${body}")" || return 3
  local p
  for p in "${PATHS[@]}"; do
    grep -Fq "${p}" <<<"${line}" || return 1
  done
  return 0
}

# route-access seeds a PUBLIC row per exact path on the fe gateway, and NO
# subtree row (a PUBLIC subtree would anonymise anything added under the prefix).
check_seed_public() {
  local body; body="$(strip_sql "$1")"
  # SUBTREE FIRST, for the same reason as check_cluster_route above.
  grep -Fq "'/bff/password-reset/**'" <<<"${body}" && return 2
  local p
  for p in "${PATHS[@]}"; do
    grep -Eq "'hugmesh-fe-gateway',[[:space:]]*'${p}'[[:space:]]*,[[:space:]]*'PUBLIC'" <<<"${body}" || return 1
  done
  return 0
}

echo "-- the four layers that must agree (three of them live in this repo) --"

check_cluster_route "${CLUSTER_FE}"
case $? in
  0) ok "cluster fe-gateway routes BOTH exact paths to user-bff (and no /** subtree)" ;;
  2) bad "cluster fe-gateway declares a /bff/password-reset/** SUBTREE — it would swallow future siblings" ;;
  *) bad "cluster fe-gateway is missing a /bff/password-reset route (20-gateway-fe.yaml)" ;;
esac

check_compose_route "${COMPOSE_FE}"
case $? in
  0) ok "compose fe-gateway predicate lists BOTH exact paths on the user-bff route" ;;
  3) bad "compose fe-gateway has no user-bff '- Path=/bff/login...' route line at all" ;;
  *) bad "compose fe-gateway predicate is missing a /bff/password-reset path (application-routes.yml)" ;;
esac

check_seed_public "${SEED}"
case $? in
  0) ok "route-access seeds a PUBLIC row for BOTH exact paths (and no /** subtree)" ;;
  2) bad "route-access seeds a PUBLIC /bff/password-reset/** SUBTREE — anonymises future siblings" ;;
  *) bad "route-access is missing a PUBLIC row for a /bff/password-reset path (20-schema.sql)" ;;
esac

# The compose lane and the cluster lane must open the SAME surface. Drift between
# them is the recurring shape of docs/KIND-SSO-E2E-FINDINGS.md, and it is invisible
# because each lane is self-consistent.
if check_cluster_route "${CLUSTER_FE}" && check_compose_route "${COMPOSE_FE}"; then
  ok "compose and cluster open the SAME two paths (no lane drift)"
else
  bad "compose and cluster disagree about the password-reset surface"
fi

# The out-of-repo layer cannot be checked, so assert that the reader is TOLD.
# A gap that is documented is a gap someone can close; an undocumented one is a
# 401 nobody can explain.
if grep -q "PUBLIC_PATHS" "${SEED}"; then
  ok "20-schema.sql names the out-of-repo hugmesh-gateway PUBLIC_PATHS dependency"
else
  bad "20-schema.sql does not mention PUBLIC_PATHS — the 4th layer is undocumented"
fi

# ── negative controls: prove each check can actually FAIL ─────────────────────
# A gate that has never been observed to go red is a gate nobody should trust.
echo
echo "-- negative controls (each breaks one layer in a temp copy) --"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# 1. cluster route deleted
sed '/path: \/bff\/password-reset\/request/d' "${CLUSTER_FE}" > "${TMP}/cluster.yaml"
if ! diff -q "${CLUSTER_FE}" "${TMP}/cluster.yaml" >/dev/null; then
  check_cluster_route "${TMP}/cluster.yaml" \
    && bad "control 'cluster route deleted': NOT caught" \
    || ok "control 'cluster route deleted': caught"
else
  bad "control 'cluster route deleted': the mutation changed nothing (anchor moved)"
fi

# 2. cluster route widened to a subtree
sed 's#path: /bff/password-reset/request#path: /bff/password-reset/**#' "${CLUSTER_FE}" > "${TMP}/wide.yaml"
if ! diff -q "${CLUSTER_FE}" "${TMP}/wide.yaml" >/dev/null; then
  check_cluster_route "${TMP}/wide.yaml"
  [[ $? -eq 2 ]] && ok "control 'cluster route widened to /**': caught" \
                 || bad "control 'cluster route widened to /**': NOT caught"
else
  bad "control 'cluster route widened': the mutation changed nothing (anchor moved)"
fi

# 3. compose predicate loses one path
sed 's#,/bff/password-reset/confirm##' "${COMPOSE_FE}" > "${TMP}/compose.yml"
if ! diff -q "${COMPOSE_FE}" "${TMP}/compose.yml" >/dev/null; then
  check_compose_route "${TMP}/compose.yml" \
    && bad "control 'compose path dropped': NOT caught" \
    || ok "control 'compose path dropped': caught"
else
  bad "control 'compose path dropped': the mutation changed nothing (anchor moved)"
fi

# 4. the PUBLIC row is downgraded to ROLE_USER — the chicken-and-egg lock-out
#    that would make the whole flow unreachable for exactly the users who need it.
sed "s#'/bff/password-reset/request', 'PUBLIC'#'/bff/password-reset/request', 'ROLE_USER'#" "${SEED}" > "${TMP}/seed.sql"
if ! diff -q "${SEED}" "${TMP}/seed.sql" >/dev/null; then
  check_seed_public "${TMP}/seed.sql" \
    && bad "control 'PUBLIC downgraded to ROLE_USER': NOT caught" \
    || ok "control 'PUBLIC downgraded to ROLE_USER': caught"
else
  bad "control 'PUBLIC downgraded': the mutation changed nothing (anchor moved)"
fi

# 5. COMMENT-ONLY control. The prose beside each declaration mentions these paths;
#    deleting the DECLARATIONS while leaving the prose must still fail. This is the
#    inversion that has produced false greens in this repo five times.
sed "/'hugmesh-fe-gateway',  '\/bff\/password-reset/d" "${SEED}" > "${TMP}/prose.sql"
if ! diff -q "${SEED}" "${TMP}/prose.sql" >/dev/null; then
  if grep -q "password-reset" "${TMP}/prose.sql"; then
    check_seed_public "${TMP}/prose.sql" \
      && bad "control 'rows deleted, prose kept': NOT caught (comment-token inversion)" \
      || ok "control 'rows deleted, prose kept': caught despite the surviving prose"
  else
    bad "control 'rows deleted, prose kept': no prose survived, control is vacuous"
  fi
else
  bad "control 'rows deleted, prose kept': the mutation changed nothing (anchor moved)"
fi

echo
echo "-- the switch (that it EXISTS, not that it is on) --"
# A FIFTH thing has to be true and it is not a file agreeing with another file:
# casdoor.password-reset.enabled. PasswordResetConfig ships the surface DARK behind
# it — every leg 503s until it is true — and keeps it deliberately separate from
# casdoor.account.enabled, because this one is permitAll and credential-WRITING and
# is undeliverable until Casdoor SMTP is provisioned.
#
# So this does NOT assert the flag is on; default-off is correct. It asserts the flag
# has an env var AT ALL. It had none, in any environment: the property existed only
# in Java, so there was no supported way to turn the feature on. A dark surface whose
# switch cannot be reached is indistinguishable from a broken one, and the four
# layers above can all be green while the whole path still 503s.
#
# BINDING: Spring maps casdoor.password-reset.enabled to CASDOOR_PASSWORD_RESET_ENABLED
# by uppercasing and replacing '.' and '-' with '_' — the same rule already carrying
# CASDOOR_ACCOUNT_BASE_URL -> casdoor.account.base-url in that same env block.
_sw_missing=""
for _f in "${REPO}/specs/cluster/manifests/user-bff-api/deployment.yaml" \
          "${REPO}/tests/stack/compose.local.yaml"; do
  if [[ ! -f ${_f} ]]; then
    _sw_missing="${_sw_missing} ${_f#"${REPO}/"}(ABSENT)"
  elif ! grep -q 'CASDOOR_PASSWORD_RESET_ENABLED' "${_f}"; then
    _sw_missing="${_sw_missing} ${_f#"${REPO}/"}"
  fi
done
if [[ -n ${_sw_missing} ]]; then
  bad "casdoor.password-reset.enabled has no env var in:${_sw_missing}
       => the property defaults to false in code, so with no env var there is no
          supported way to enable the feature; every leg 503s and the four layers
          above cannot tell you why."
else
  ok "CASDOOR_PASSWORD_RESET_ENABLED exists in both the cluster deployment and compose"
fi

echo
echo "== password-reset front door: ${pass} passed, ${fail} failed =="
[[ ${fail} -eq 0 ]]

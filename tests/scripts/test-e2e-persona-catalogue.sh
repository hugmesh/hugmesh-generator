#!/usr/bin/env bash
# test-e2e-persona-catalogue.sh — the compose lane and the kind lane must seed the
# SAME e2e personas.
#
# WHY THIS EXISTS. Two lanes seeded Casdoor from two different lists:
#
#   compose  tests/stack/seed-e2e.sh    BASE_SPECS + its own inlined EXTRA_SPECS
#   kind     bootstrap-kind.sh          seed-accounts.sh --roles, no override at all
#
# seed-accounts.sh's SYSTEMS_ROLE_USERS is an OVERRIDE, not an addition, so a caller
# wanting one extra persona had to restate the whole base catalogue. The compose lane
# did that. The kind lane did not, and therefore seeded no extras whatsoever.
#
# Live symptom, 2026-08-06, against a cluster where everything else worked — casdoor
# seeded, Cassandra roles created, PKI issuing, spec 27 logging in end to end:
#
#     native login e2e-fleet -> 401 — the persona must be seeded
#
# which reads like a broken login and is really a persona that was never created.
# The same shape as the Cassandra role that did not exist reading as a rotated
# password. Compose right, cluster behind — the theme of the whole findings doc.
#
# THE INVARIANT, deliberately dumb:
#
#   1. tests/e2e-extra-personas.sh is the ONE definition; both lanes source it.
#   2. The kind lane passes it to seed-accounts.sh as EXTRA_ROLE_USERS.
#   3. seed-accounts.sh APPENDS EXTRA_ROLE_USERS rather than ignoring it — checked by
#      EXECUTING the real assignment block out of the real file, not by grepping for
#      a line that looks right.
#   4. Every persona in the shared file survives into the resolved kind catalogue.
#
# Offline: bash + grep + sed only. No cluster, no network, no Casdoor.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

# Control runs re-enter this script against synthetic trees. POSITIONAL, never an
# env var: an inherited env var would silently downgrade a real CI run to a control
# run and skip every control, with nothing saying so.
CHILD=no
[ "${1:-}" = "--scan-only" ] && CHILD=yes

if [ "${CHILD}" = yes ]; then
  ROOT="${PERSONA_TREE:-${REPO}}"
else
  ROOT="${REPO}"
fi

EXTRAS="${ROOT}/tests/e2e-extra-personas.sh"
SEED_ACCOUNTS="${ROOT}/tests/qemu/seed-accounts.sh"
SEED_E2E="${ROOT}/tests/stack/seed-e2e.sh"
BOOTSTRAP="${ROOT}/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

for t in grep sed; do
  command -v "$t" >/dev/null 2>&1 || { echo "FATAL: ${t} required (refusing to skip)" >&2; exit 1; }
done

for f in "${EXTRAS}" "${SEED_ACCOUNTS}" "${SEED_E2E}" "${BOOTSTRAP}"; do
  [ -r "${f}" ] || { echo "FATAL: missing ${f}" >&2; exit 1; }
done

# ── Resolve the catalogue by RUNNING the real code. Extract seed-accounts.sh's
#    SYSTEMS_ROLE_USERS block — the default assignment through the append — and
#    evaluate it in a subshell with EXTRA_ROLE_USERS set, exactly as the kind lane
#    invokes it. Grepping for a line that "looks like" an append would pass on a
#    line that is commented out, quoted wrong, or shadowed three lines later.
BLK="$(sed -n '/^SYSTEMS_ROLE_USERS="\${SYSTEMS_ROLE_USERS:-/,/^SYSTEMS_ROLE_USERS="\${SYSTEMS_ROLE_USERS} /p' "${SEED_ACCOUNTS}")"

resolve() { # <extras-string> -> the resolved catalogue
  ( unset SYSTEMS_ROLE_USERS
    EXTRA_ROLE_USERS="$1"
    eval "${BLK}" 2>/dev/null
    printf '%s\n' "${SYSTEMS_ROLE_USERS:-}" )
}

names() { tr ' ' '\n' | sed 's/:.*//' | grep -v '^$' | sort -u; }

# >>> RULE_BLOCK
if [ -z "${BLK}" ]; then
  bad "could not extract seed-accounts.sh's SYSTEMS_ROLE_USERS block — the shape moved; this guard proves NOTHING until it is re-pointed"
else
  # shellcheck source=/dev/null
  EXTRA_LIST="$( . "${EXTRAS}"; printf '%s\n' "${E2E_EXTRA_PERSONAS:-}" )"
  if [ -z "${EXTRA_LIST// /}" ]; then
    bad "tests/e2e-extra-personas.sh defines no E2E_EXTRA_PERSONAS"
  else
    base="$(resolve "" | names)"
    with="$(resolve "${EXTRA_LIST}" | names)"

    # RULE 3 — the append is real: adding extras must actually change the catalogue.
    if [ "${base}" = "${with}" ]; then
      bad "seed-accounts.sh IGNORES EXTRA_ROLE_USERS — the resolved catalogue is identical with and without it, so every extra persona is silently dropped"
    else
      ok "seed-accounts.sh appends EXTRA_ROLE_USERS (catalogue grows from $(echo "${base}" | wc -l) to $(echo "${with}" | wc -l) personas)"
    fi

    # RULE 4 — every shared persona survives into the resolved catalogue.
    missing=""
    while read -r p; do
      [ -n "${p}" ] || continue
      echo "${with}" | grep -xF "${p}" >/dev/null || missing="${missing} ${p}"
    done <<< "$(printf '%s\n' "${EXTRA_LIST}" | names)"
    if [ -n "${missing}" ]; then
      bad "personas defined in the shared file never reach the kind catalogue:${missing}"
    else
      ok "all $(printf '%s\n' "${EXTRA_LIST}" | names | wc -l) shared personas survive into the resolved catalogue"
    fi
  fi

  # RULE 1 — both lanes source the ONE definition.
  for lane in "${SEED_E2E}:compose" "${BOOTSTRAP}:kind"; do
    f="${lane%:*}"; label="${lane##*:}"
    if grep -q 'e2e-extra-personas\.sh' "${f}"; then
      ok "${label} lane sources tests/e2e-extra-personas.sh"
    else
      bad "${label} lane ($(basename "${f}")) does NOT source tests/e2e-extra-personas.sh — it is back to its own private list, which is the exact divergence this guard exists to stop"
    fi
  done

  # RULE 2 — the kind lane actually hands the list over.
  if grep -q 'EXTRA_ROLE_USERS="\${E2E_EXTRA_PERSONAS}"' "${BOOTSTRAP}"; then
    ok "kind lane passes EXTRA_ROLE_USERS=\${E2E_EXTRA_PERSONAS} to seed-accounts.sh"
  else
    bad "kind lane sources the shared list but never passes it as EXTRA_ROLE_USERS — sourcing alone seeds nothing"
  fi

  # RULE 5 — every role the AUTHORIZATION rows grant must be a role Casdoor creates.
  #
  # Seeding the personas exposed the layer under them: apply-systems-roles.sh
  # refused with "role hugmesh/ROLE_FLEET_ADMIN does not exist in Casdoor", and it
  # was right to. route-access/initdb/20-schema.sql seeds a LIVE authorization row
  #   ('hugmesh-fe-gateway', '/bff/admin/phone-fleet/**', 'ROLE_FLEET_ADMIN', true)
  # while init-data-configmap.yaml never declared that role — so no account on any
  # cluster could ever hold it and the fleet-owner phone console was unreachable.
  # Not a test-only defect: the authz source of truth referenced an identity the
  # IdP never creates. Grepping both sides is dumb, offline and unevadable.
  ROWS_SQL="${ROOT}/specs/cluster/manifests/route-access/initdb/20-schema.sql"
  CASDOOR_DIR="${ROOT}/specs/cluster/manifests/casdoor"
  if [ ! -r "${ROWS_SQL}" ] || [ ! -d "${CASDOOR_DIR}" ]; then
    bad "cannot compare authz roles to the Casdoor seed (missing ${ROWS_SQL} or ${CASDOOR_DIR}) — this rule proves NOTHING"
  else
    _rows="$(grep -ohE "'ROLE_[A-Z_]+'" "${ROWS_SQL}" | tr -d "'" | sort -u)"
    _decl="$(grep -rhoE '"name":[[:space:]]*"ROLE_[A-Z_]+"' "${CASDOOR_DIR}" | grep -oE 'ROLE_[A-Z_]+' | sort -u)"
    if [ -z "${_rows}" ] || [ -z "${_decl}" ]; then
      bad "extracted 0 roles from one side (rows=$(echo "${_rows}" | grep -c .), declared=$(echo "${_decl}" | grep -c .)) — the shape moved; this rule proves NOTHING"
    else
      _undeclared="$(comm -23 <(printf '%s\n' "${_rows}") <(printf '%s\n' "${_decl}") | tr '\n' ' ')"
      if [ -n "${_undeclared// /}" ]; then
        bad "authorization rows grant roles Casdoor never creates:${_undeclared}— no account can hold them, so those surfaces are unreachable on every cluster"
      else
        ok "all $(printf '%s\n' "${_rows}" | grep -c .) roles named in route-access rows are declared in the Casdoor seed"
      fi
    fi
  fi
fi
# <<< RULE_BLOCK

# ── Anti-rot: properties of the REAL repo, never of a synthetic probe. Running
#    them in child runs would make every control fail for the wrong reason.
if [ "${CHILD}" = no ]; then
  echo
  n_extra="$( . "${EXTRAS}"; printf '%s\n' "${E2E_EXTRA_PERSONAS}" | names | wc -l )"
  if [ "${n_extra}" -ge 10 ]; then
    ok "anti-rot: ${n_extra} personas in the shared file (>=10)"
  else
    bad "anti-rot: only ${n_extra} personas in the shared file — the list has been gutted, or this guard is reading the wrong thing"
  fi
  if ( . "${EXTRAS}"; printf '%s\n' "${E2E_EXTRA_PERSONAS}" ) | grep 'e2e-fleet:ROLE_FLEET_ADMIN' >/dev/null; then
    ok "anti-rot: e2e-fleet is still a PURE fleet owner (the persona whose absence started this, and whose ROLE_ADMIN would make spec 29 vacuous)"
  else
    bad "anti-rot: e2e-fleet is missing or no longer ROLE_FLEET_ADMIN-without-ROLE_ADMIN — spec 29's gateway MFA leg goes vacuous"
  fi
fi

if [ "${CHILD}" = yes ]; then
  echo "== e2e persona catalogue: ${pass} passed, ${fail} failed =="
  [ "${fail}" -eq 0 ]
  exit $?
fi

echo
echo "-- negative controls --"

T="$(mktemp -d)"
case "$(realpath "${T}")" in
  /tmp/*|/var/tmp/*) : ;;
  *) echo "FATAL: refusing to write controls outside a temp dir: ${T}" >&2; exit 1 ;;
esac
cleanup() { case "$(realpath "${T}" 2>/dev/null)" in /tmp/*|/var/tmp/*) rm -rf "${T}" ;; esac; }
trap cleanup EXIT

# Stage against the REAL files, then mutate ONE thing. A fixture simpler than
# production tests a shape that does not ship.
stage() { # <dir>
  mkdir -p "$1/tests/qemu" "$1/tests/stack" "$1/specs/cluster/bootstrap/kind-local" \
           "$1/specs/cluster/manifests/route-access/initdb" "$1/specs/cluster/manifests/casdoor"
  cp "${EXTRAS}"       "$1/tests/e2e-extra-personas.sh"
  cp "${SEED_ACCOUNTS}" "$1/tests/qemu/seed-accounts.sh"
  cp "${SEED_E2E}"      "$1/tests/stack/seed-e2e.sh"
  cp "${BOOTSTRAP}"     "$1/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"
  # EVERY file a rule reads, not just the ones the current controls mutate. Adding
  # rule 5 without adding these made all three pairs report "the CORRECTED probe
  # also failed" — the pair design refusing to score, exactly as intended, instead
  # of a lone "the bad probe failed" assertion quietly passing on a broken fixture.
  cp "${ROOT}/specs/cluster/manifests/route-access/initdb/20-schema.sql" \
     "$1/specs/cluster/manifests/route-access/initdb/20-schema.sql"
  cp "${ROOT}/specs/cluster/manifests/casdoor/init-data-configmap.yaml" \
     "$1/specs/cluster/manifests/casdoor/init-data-configmap.yaml"
}
run_probe() { PERSONA_TREE="$1" bash "${BASH_SOURCE[0]}" --scan-only >/dev/null 2>&1; }
pair() { # <name> <bad> <good>
  if run_probe "$2"; then
    bad "control '$1': the DEFECTIVE probe was not caught"
  elif ! run_probe "$3"; then
    bad "control '$1': the CORRECTED probe also failed — the control cannot distinguish, so it proves nothing"
  else
    ok "control '$1': defective probe caught, corrected probe clean"
  fi
}

stage "${T}/good"

# 1. seed-accounts.sh drops the append (its pre-fix state): extras vanish silently.
stage "${T}/b1"
sed -i 's|^SYSTEMS_ROLE_USERS="\${SYSTEMS_ROLE_USERS} \${EXTRA_ROLE_USERS:-}"|SYSTEMS_ROLE_USERS="${SYSTEMS_ROLE_USERS}"|' \
  "${T}/b1/tests/qemu/seed-accounts.sh"
pair "seed-accounts.sh ignores EXTRA_ROLE_USERS" "${T}/b1" "${T}/good"

# 2. the kind lane stops handing the list over (its exact pre-fix state).
stage "${T}/b2"
sed -i 's|EXTRA_ROLE_USERS="\${E2E_EXTRA_PERSONAS}" \\||' \
  "${T}/b2/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"
pair "kind lane does not pass EXTRA_ROLE_USERS" "${T}/b2" "${T}/good"

# 3. a lane goes back to its own private list.
stage "${T}/b3"
sed -i 's|e2e-extra-personas\.sh|e2e-private-list.sh|g' "${T}/b3/tests/stack/seed-e2e.sh"
pair "compose lane stops sourcing the shared definition" "${T}/b3" "${T}/good"

# 4. THE EXACT PRE-FIX STATE of the role half: the authz row exists, the Casdoor
#    declaration does not. This is what made apply-systems-roles.sh refuse.
stage "${T}/b4"
sed -i '/"name": "ROLE_FLEET_ADMIN"/d' "${T}/b4/specs/cluster/manifests/casdoor/init-data-configmap.yaml"
pair "authz row grants a role Casdoor never creates" "${T}/b4" "${T}/good"

# NOT A CONTROL, deliberately: "a persona is deleted from the shared file" cannot
# be caught by rule 4, because rule 4 compares the file against the catalogue and
# both shrink together. That case is the parent-only anti-rot check above (count
# floor + the e2e-fleet shape). An earlier draft staged a probe for it anyway and
# never paired it — dead staging that reads like coverage it does not provide.

# THE SABOTAGE CONTROL. Blank the rule block and require a pair to stop failing.
#    Sentinels, not a source-shaped regex: a sed range built from the guard's own
#    text can match the sed itself and eat the rest of the file.
SAB="${T}/sabotage.sh"
sed '/^# >>> RULE_BLOCK$/,/^# <<< RULE_BLOCK$/c\
:' "${BASH_SOURCE[0]}" > "${SAB}"

sab_ready=yes
if [ ! -s "${SAB}" ]; then
  bad "sabotage control: the sabotaged copy is empty — sed produced nothing, so this control proves NOTHING"; sab_ready=no
elif cmp -s "${SAB}" "${BASH_SOURCE[0]}"; then
  bad "sabotage control: the sabotaged copy is IDENTICAL to the original — the mutation never landed"; sab_ready=no
elif ! bash -n "${SAB}" 2>/dev/null; then
  bad "sabotage control: the sabotaged copy is not valid bash — it would fail for an unrelated reason"; sab_ready=no
elif grep -q '^# >>> RULE_BLOCK$' "${SAB}"; then
  bad "sabotage control: the rule block was not blanked — the source shape moved"; sab_ready=no
fi

if [ "${sab_ready}" = yes ]; then
  if PERSONA_TREE="${T}/b1" bash "${SAB}" --scan-only >/dev/null 2>&1; then
    ok "sabotage control: with the rule block blanked, the defective probe is NO LONGER caught — the controls really do exercise it"
  else
    bad "sabotage control: the defective probe still 'fails' with the rules blanked — the controls are measuring something else"
  fi
fi

echo
echo "== e2e persona catalogue: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]

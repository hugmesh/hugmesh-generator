#!/usr/bin/env bash
# pg-tls-preflight.sh — may PG_TLS_ENABLED be flipped to "true" for this
# Postgres DB yet? READ-ONLY: it never edits, applies, restarts or deletes.
#
# WHY THIS EXISTS. Each of the nine dedicated Postgres Deployments mounts its
# Vault-PKI server cert from the ESO Secret <db>-mtls with `optional: true`, so
# the pod starts fine before ESO has materialised it. That is exactly what makes
# the flip dangerous:
#
#   PG_TLS_ENABLED=true  +  <db>-mtls absent/empty  =>  pg-tls-entrypoint.sh adds
#   `-c ssl=on -c ssl_cert_file=/etc/postgres-tls/tls.crt ...` and Postgres exits
#   "could not load server certificate file". The Deployment strategy is
#   Recreate (single writer over a RWO PVC), so the old, healthy pod is already
#   gone: the DB is DOWN until the change is reverted in git.
#
# Nothing in the tree stops that: the volume is optional, the env var is a
# literal, and the ArgoCD Application auto-syncs main with selfHeal. This script
# is the stop. Run it per DB immediately before the change that flips the gate.
#
# WHAT IT CHECKS, per DB (all fail CLOSED: a kubectl that cannot answer is a
# FAIL, never a silent pass):
#   deployment  exists, 1/1 ready now (a flip must not start from a sick DB),
#               pod fsGroup is 70 (else postgres cannot read the 0600 key and
#               crash-loops), volume pg-tls names <db>-mtls
#   eso         ExternalSecret <db>-mtls reports Ready=True
#   secret      Secret <db>-mtls is kubernetes.io/tls with non-empty tls.crt,
#               tls.key and ca.crt
#   cert        (openssl) not expiring inside --min-days, SANs cover <db>,
#               <db>.<ns> and <db>.<ns>.svc.cluster.local, key matches cert,
#               chains to ca.crt, EKU (if present) allows server auth
# After the flip, --post checks the live result: gate is "true", 1/1 ready, the
# wrapper logged that it enabled ssl, and the server answers `show ssl` = on.
#
# USAGE
#   scripts/pg-tls-preflight.sh [--db NAME]... [--post] [--min-days N]
#                               [--context CTX] [--list]
#   --db NAME    only this DB (repeatable); default: all nine, in flip order
#   --post       verify AFTER the flip instead of before
#   --min-days N cert must outlive N days (default 14; refresh is 168h, ttl 720h)
#   --context C  kubectl --context C
#   --list       print "<db> <namespace>" in recommended flip order and exit 0
# ENV  KUBECTL   kubectl binary/command (default: kubectl)
#
# EXIT  0 every selected DB passes   1 at least one check failed
#       2 usage / kubectl or a required tool missing
#       3 nothing failed but a check could not run (openssl missing): UNVERIFIED
#
# The DB table below is pinned to the manifests by
# tests/scripts/test-pg-tls-preflight.sh; docs/DB-HARDENING-RUNBOOK.md explains
# the order.
set -uo pipefail

# name namespace — RECOMMENDED FLIP ORDER, lowest blast radius first. The two
# that sit on the sign-in path come late and route-access-db (every gateway reads
# it) comes last. See docs/DB-HARDENING-RUNBOOK.md for the reasoning.
DB_TABLE=(
  "wiki-bff-db hugmesh-backend"
  "mesh-bff-db hugmesh-backend"
  "character-forge-bff-db hugmesh-backend"
  "forum-bff-db hugmesh-backend"
  "mod-bff-db hugmesh-backend"
  "user-bff-db hugmesh-backend"
  "federation-db hugmesh-backend"
  "admin-bff-db hugmesh-backend"
  "route-access-db hugmesh-pki"
)

PG_UID_GROUP=70
MARKER='PG_TLS_ENABLED=true -> Postgres ssl=on'

MIN_DAYS=14
CONTEXT=""
POST=0
SELECT=()
while [ $# -gt 0 ]; do
  case "$1" in
    --db)       [ $# -ge 2 ] || { echo "usage: --db needs a name" >&2; exit 2; }
                SELECT+=("$2"); shift 2 ;;
    --post)     POST=1; shift ;;
    --min-days) [ $# -ge 2 ] || { echo "usage: --min-days needs a number" >&2; exit 2; }
                MIN_DAYS="$2"; shift 2 ;;
    --context)  [ $# -ge 2 ] || { echo "usage: --context needs a name" >&2; exit 2; }
                CONTEXT="$2"; shift 2 ;;
    --list)     for row in "${DB_TABLE[@]}"; do echo "$row"; done; exit 0 ;;
    -h|--help)  sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    *)          echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done
case "$MIN_DAYS" in ''|*[!0-9]*) echo "--min-days must be a whole number" >&2; exit 2 ;; esac

read -r -a KC <<<"${KUBECTL:-kubectl}"
command -v "${KC[0]}" >/dev/null 2>&1 || { echo "FAIL ${KC[0]} is not on PATH" >&2; exit 2; }
if [ -n "$CONTEXT" ]; then KC+=(--context "$CONTEXT"); fi

HAVE_OPENSSL=1
command -v openssl >/dev/null 2>&1 || HAVE_OPENSSL=0

# Resolve the selection against the table, so a typo is a usage error, not a
# silently empty run that exits 0.
ROWS=()
if [ "${#SELECT[@]}" -eq 0 ]; then
  ROWS=("${DB_TABLE[@]}")
else
  for want in "${SELECT[@]}"; do
    found=""
    for row in "${DB_TABLE[@]}"; do
      if [ "${row%% *}" = "$want" ]; then found="$row"; fi
    done
    [ -n "$found" ] || { echo "unknown DB '$want' (known: $(for r in "${DB_TABLE[@]}"; do printf '%s ' "${r%% *}"; done))" >&2; exit 2; }
    ROWS+=("$found")
  done
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pg-tls-preflight.XXXXXX")" || { echo "FAIL mktemp" >&2; exit 2; }
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0; UNVER=0
pass(){ echo "  PASS $*"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL $*"; FAIL=$((FAIL+1)); }
unver(){ echo "  UNVERIFIED $*"; UNVER=$((UNVER+1)); }
info(){ echo "  info $*"; }

# jp KIND NAME NAMESPACE JSONPATH -> stdout; rc is kubectl's. A missing object is
# a non-zero rc; an existing object with an absent field is rc 0 and empty.
jp(){ "${KC[@]}" get "$1" "$2" -n "$3" -o "jsonpath=$4" 2>"$WORK/err"; }
why(){ tr '\n' ' ' <"$WORK/err" | cut -c1-200; }

# The jsonpath expressions. They are pinned against real kubectl in the suite.
JP_GATE='{.spec.template.spec.containers[0].env[?(@.name=="PG_TLS_ENABLED")].value}'
JP_FSGROUP='{.spec.template.spec.securityContext.fsGroup}'
JP_VOLSECRET='{.spec.template.spec.volumes[?(@.name=="pg-tls")].secret.secretName}'
JP_READY='{.status.readyReplicas}'
JP_ESREADY='{.status.conditions[?(@.type=="Ready")].status}'
JP_SECTYPE='{.type}'

# deployment_checks DB NS — the checks both modes share.
deployment_state(){
  local db="$1" ns="$2" out rc
  out="$(jp deployment "$db" "$ns" '{.metadata.name}')"; rc=$?
  if [ $rc -ne 0 ] || [ "$out" != "$db" ]; then
    fail "deployment/$db not readable in $ns ($(why))"; return 1
  fi
  pass "deployment/$db exists in $ns"
  return 0
}

ready_check(){
  local db="$1" ns="$2" out rc
  out="$(jp deployment "$db" "$ns" "$JP_READY")"; rc=$?
  if [ $rc -eq 0 ] && [ "$out" = "1" ]; then pass "deployment/$db is 1/1 ready"
  else fail "deployment/$db readyReplicas='${out}' (want 1; $(why))"; fi
}

secret_checks(){
  local db="$1" ns="$2" sec out rc k
  sec="${db}-mtls"
  out="$(jp externalsecret "$sec" "$ns" "$JP_ESREADY")"; rc=$?
  if [ $rc -ne 0 ]; then fail "externalsecret/$sec not readable in $ns ($(why))"
  elif [ "$out" = "True" ]; then pass "externalsecret/$sec Ready=True"
  else fail "externalsecret/$sec Ready='${out}' (want True)"; fi

  out="$(jp secret "$sec" "$ns" "$JP_SECTYPE")"; rc=$?
  if [ $rc -ne 0 ]; then
    fail "secret/$sec does not exist in $ns — flipping now would crash-loop the DB ($(why))"
    return 1
  fi
  if [ "$out" = "kubernetes.io/tls" ]; then pass "secret/$sec is type kubernetes.io/tls"
  else fail "secret/$sec type='${out}' (want kubernetes.io/tls)"; fi

  local have_all=1
  for k in tls.crt tls.key ca.crt; do
    out="$(jp secret "$sec" "$ns" "{.data.${k//./\\.}}")"; rc=$?
    if [ $rc -ne 0 ] || [ -z "$out" ]; then
      fail "secret/$sec key $k is missing or empty"; have_all=0; continue
    fi
    if ! printf '%s' "$out" | base64 -d >"$WORK/$db.$k" 2>/dev/null || [ ! -s "$WORK/$db.$k" ]; then
      fail "secret/$sec key $k is not valid base64"; have_all=0; continue
    fi
    chmod 600 "$WORK/$db.$k"
    pass "secret/$sec key $k present"
  done
  [ "$have_all" -eq 1 ] || return 1
  return 0
}

cert_checks(){
  local db="$1" ns="$2" crt key ca want san eku a b
  crt="$WORK/$db.tls.crt"; key="$WORK/$db.tls.key"; ca="$WORK/$db.ca.crt"
  if [ "$HAVE_OPENSSL" -ne 1 ]; then
    unver "openssl is not installed: cert content of $db-mtls (expiry, SANs, key match, chain) NOT checked"
    return 0
  fi
  if ! openssl x509 -in "$crt" -noout 2>/dev/null; then
    fail "$db-mtls tls.crt does not parse as an X.509 certificate"; return 1
  fi
  if openssl x509 -in "$crt" -noout -checkend $((MIN_DAYS * 86400)) >/dev/null 2>&1; then
    pass "cert outlives ${MIN_DAYS} days"
  else
    fail "cert expires inside ${MIN_DAYS} days (or already has): $(openssl x509 -in "$crt" -noout -enddate 2>/dev/null)"
  fi
  san="$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null)"
  for want in "$db" "$db.$ns" "$db.$ns.svc.cluster.local"; do
    case "$san" in
      *"DNS:$want,"*|*"DNS:$want") pass "SAN covers $want" ;;
      *"DNS:$want "*)              pass "SAN covers $want" ;;
      *)                           fail "SAN does not cover $want" ;;
    esac
  done
  eku="$(openssl x509 -in "$crt" -noout -ext extendedKeyUsage 2>/dev/null)"
  if [ -z "$eku" ]; then pass "no EKU restriction (server auth allowed)"
  else
    case "$eku" in *"TLS Web Server Authentication"*) pass "EKU allows server auth" ;;
                   *) fail "EKU present but lacks TLS Web Server Authentication" ;; esac
  fi
  a="$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null)"
  b="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256 2>/dev/null)"
  if [ -n "$a" ] && [ "$a" = "$b" ]; then pass "tls.key matches tls.crt"
  else fail "tls.key does not match tls.crt (or the key does not parse)"; fi
  if openssl verify -partial_chain -CAfile "$ca" "$crt" >/dev/null 2>&1; then
    pass "tls.crt chains to ca.crt"
  else fail "tls.crt does not verify against ca.crt"; fi
}

pre_checks(){
  local db="$1" ns="$2" out rc
  deployment_state "$db" "$ns" || return
  out="$(jp deployment "$db" "$ns" "$JP_GATE")"
  case "$out" in
    false) info "PG_TLS_ENABLED is currently \"false\" (flip pending)" ;;
    true)  info "PG_TLS_ENABLED is already \"true\" — use --post to verify the result" ;;
    *)     fail "PG_TLS_ENABLED is '${out}' (want \"false\" or \"true\"): the gate is not where this script expects it" ;;
  esac
  out="$(jp deployment "$db" "$ns" "$JP_FSGROUP")"; rc=$?
  if [ $rc -eq 0 ] && [ "$out" = "$PG_UID_GROUP" ]; then pass "pod fsGroup is $PG_UID_GROUP"
  else fail "pod fsGroup='${out}' (want $PG_UID_GROUP): postgres cannot read the 0600 tls.key"; fi
  out="$(jp deployment "$db" "$ns" "$JP_VOLSECRET")"; rc=$?
  if [ $rc -eq 0 ] && [ "$out" = "${db}-mtls" ]; then pass "volume pg-tls mounts ${db}-mtls"
  else fail "volume pg-tls secretName='${out}' (want ${db}-mtls)"; fi
  ready_check "$db" "$ns"
  if secret_checks "$db" "$ns"; then cert_checks "$db" "$ns"; fi
}

post_checks(){
  local db="$1" ns="$2" out rc
  deployment_state "$db" "$ns" || return
  out="$(jp deployment "$db" "$ns" "$JP_GATE")"
  if [ "$out" = "true" ]; then pass "live PG_TLS_ENABLED is \"true\""
  else fail "live PG_TLS_ENABLED='${out}' (want true): the change has not synced"; fi
  ready_check "$db" "$ns"
  out="$("${KC[@]}" logs "deployment/$db" -n "$ns" --tail=400 2>"$WORK/err")"; rc=$?
  if [ $rc -ne 0 ]; then fail "logs of deployment/$db unreadable ($(why))"
  else
    case "$out" in
      *"$MARKER"*) pass "wrapper logged: $MARKER" ;;
      *)           fail "wrapper did not log '$MARKER' in the last 400 lines" ;;
    esac
  fi
  out="$("${KC[@]}" exec -n "$ns" "deployment/$db" -- sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "show ssl"' \
    2>"$WORK/err")"; rc=$?
  out="$(printf '%s' "$out" | tr -d '[:space:]')"
  if [ $rc -eq 0 ] && [ "$out" = "on" ]; then pass "server answers: show ssl = on"
  else fail "show ssl='${out}' rc=$rc (want on; $(why))"; fi
}

MODE="pre"; [ "$POST" -eq 1 ] && MODE="post"
echo "== pg-tls preflight (${MODE}): ${#ROWS[@]} DB(s), min cert life ${MIN_DAYS}d =="
for row in "${ROWS[@]}"; do
  db="${row%% *}"; ns="${row#* }"
  echo "-- $db ($ns)"
  if [ "$POST" -eq 1 ]; then post_checks "$db" "$ns"; else pre_checks "$db" "$ns"; fi
done

echo "== ${PASS} passed, ${FAIL} failed, ${UNVER} unverified =="
if [ "$FAIL" -gt 0 ]; then
  echo "NOT READY: do not flip PG_TLS_ENABLED for the DB(s) above."
  exit 1
fi
if [ "$UNVER" -gt 0 ]; then
  echo "UNVERIFIED: install openssl and re-run before flipping."
  exit 3
fi
if [ "$POST" -eq 1 ]; then echo "OK: TLS is live on every selected DB."
else echo "READY: every selected DB has a usable <db>-mtls Secret."; fi
exit 0

#!/usr/bin/env bash
# seed-vault-kv.sh — IDEMPOTENT Vault KV seed for the kind SSO slice.
#
# Wraps scripts/gen-cluster-secrets.sh (ONLINE mode) with the already-done guard
# its neighbours in bootstrap-kind.sh all have — the cluster-CA mint
# ("cluster-ca Secret already present — keeping it"), the Vault init
# ("Vault already initialized (idempotent re-run)") and the KV-mount enable
# ("mount it here, idempotently") — and which the KV seed itself did NOT have.
#
# WHY THAT MATTERED. gen-cluster-secrets.sh mints EVERY password unconditionally
# with `openssl rand` and `vault kv put`s it, replacing whatever was there. The
# Postgres instances behind those passwords do NOT re-read them: initdb only runs
# on an EMPTY PGDATA, so the databases keep the FIRST run's passwords forever.
# A second `make kind-up` therefore rotated Vault, ESO re-materialized the k8s
# Secrets, and the BFFs came back with credentials their databases had never
# heard of:
#     FATAL: password authentication failed for user "userbff"
# i.e. the step documented as "safe to re-run" wedged the cluster it claimed to
# converge. (Hit live; that is the reproduction, not a hypothesis.)
#
# CONTRACT
#   all sentinel paths populated  -> SKIP (converged; exit 0, seeder not run)
#   no sentinel path populated    -> SEED (first run)
#   SOME populated, some not      -> FAIL. That is an interrupted/partial first
#                                    run: re-seeding would re-mint the paths that
#                                    already exist (the wedge above) and skipping
#                                    would leave ESO unable to resolve the rest.
#                                    Refuse and tell the operator, rather than
#                                    pick one and be wrong silently.
#   KIND_KV_RESEED=1              -> seed regardless (explicit, DESTRUCTIVE
#                                    opt-in: only correct together with a fresh
#                                    cluster or wiped PVCs).
#
# Requires a `vault` CLI on PATH and VAULT_TOKEN. bootstrap-kind.sh supplies a
# PATH shim that execs the CLI already inside vault-0, so no host vault binary
# and no cert plumbing is needed here. Any extra args are passed through to
# gen-cluster-secrets.sh (bootstrap-kind.sh passes `--out <tmp>/bundle`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../../../.." && pwd)}"
SEEDER="${SEEDER:-${REPO_ROOT}/scripts/gen-cluster-secrets.sh}"

# Resolve BRAND / VAULT_KV_MOUNT the way gen-cluster-secrets.sh does — built-in
# default, then ./brand.conf, then brands/<BRAND>.conf, with the conf files
# WINNING over the environment (that is genuinely the seeder's order: it applies
# the env defaults first and sources the conf files afterwards). The probe below
# has to read the SAME KV base path the seeder writes, or it would decide
# "unseeded" forever against a brand-configured checkout. Sourced in a subshell
# so nothing else out of those files leaks into this script.
_resolve() { # <var-name>
  (
    set +u
    BRAND="${BRAND:-hugmesh}"
    VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
    if [ -f "${REPO_ROOT}/brand.conf" ]; then . "${REPO_ROOT}/brand.conf"; fi
    if [ -n "${BRAND:-}" ] && [ -f "${REPO_ROOT}/brands/${BRAND}.conf" ]; then
      . "${REPO_ROOT}/brands/${BRAND}.conf"
    fi
    eval "printf '%s' \"\${$1}\""
  )
}
BRAND="$(_resolve BRAND)";                   BRAND="${BRAND:-hugmesh}"
VAULT_KV_MOUNT="$(_resolve VAULT_KV_MOUNT)"; VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
KIND_KV_RESEED="${KIND_KV_RESEED:-0}"

log()  { echo "==> [kv-seed] $*"; }
warn() { echo "    [kv-seed] WARN: $*" >&2; }
die()  { echo "    [kv-seed] FATAL: $*" >&2; exit 1; }

command -v vault >/dev/null 2>&1 || die "no 'vault' on PATH (bootstrap-kind.sh supplies an exec shim into vault-0)"
[ -n "${VAULT_TOKEN:-}" ] || die "VAULT_TOKEN is empty — cannot probe or seed Vault KV"
[ -f "${SEEDER}" ] || die "seeder not found: ${SEEDER}"

# SENTINEL PATHS — the subset of gen-cluster-secrets.sh's KV documents whose
# re-minting is what wedges an already-running SSO slice. Each backs a credential
# that is baked into persistent state on first use and never re-read:
#   casdoor          casdoor-pg's initdb password + the Casdoor admin password
#   admin-bff-db     admin-bff Postgres initdb (owner + app role)
#   user-bff-db      user-bff Postgres initdb  (owner + app role) — the path that
#                    produced the live 'password authentication failed for user
#                    "userbff"' crash
#   route-access-db  route-access Postgres initdb (owner + 5 machine users)
#   cassandra-admin  Cassandra superuser password (persisted in the system tables)
# casdoor-apps is included too: the OIDC client secrets are written into the
# Casdoor DB by casdoor-init on first run, so rotating them in Vault alone leaves
# the BFFs holding a secret Casdoor no longer accepts.
#   cassandra-app-creds  the per-app Cassandra role passwords. Added when the sso
#                    profile started applying apps/00b-cassandra-init.yaml: that
#                    Job reads every key of the derived Secret (admin-bff,
#                    pki-gateway, be-gateway, fe-gateway, superadmin-gateway,
#                    federation) to CREATE the roles, and the roles then persist
#                    in Cassandra's system tables exactly like cassandra-admin
#                    does. Without it here, a partial first run that happened to
#                    populate the other six paths would be judged "converged",
#                    the seeder would SKIP, and ESO could never resolve the one
#                    path the role bootstrap depends on.
SENTINEL_PATHS=(casdoor casdoor-apps admin-bff-db user-bff-db route-access-db cassandra-admin cassandra-app-creds)

kv_populated() { # <relative-path> -> 0 when the doc exists AND carries data
  local p="$1" out
  out="$(vault kv get -format=json "${VAULT_KV_MOUNT}/${BRAND}/${p}" 2>/dev/null)" || return 1
  printf '%s' "${out}" | jq -e '(.data.data // {}) | length > 0' >/dev/null 2>&1
}

command -v jq >/dev/null 2>&1 || die "jq is required to read the Vault KV probe output"

present=(); absent=()
for p in "${SENTINEL_PATHS[@]}"; do
  if kv_populated "${p}"; then present+=("${p}"); else absent+=("${p}"); fi
done

if [ "${KIND_KV_RESEED}" = "1" ]; then
  warn "KIND_KV_RESEED=1 — re-minting every secret even though ${#present[@]}/${#SENTINEL_PATHS[@]} sentinel path(s) are already populated."
  warn "This ROTATES credentials that existing Postgres/Cassandra volumes will NOT re-read. Only correct against a fresh cluster or wiped PVCs."
elif [ "${#absent[@]}" -eq 0 ]; then
  log "Vault KV already seeded (${SENTINEL_PATHS[*]} all populated under ${VAULT_KV_MOUNT}/${BRAND}/) — keeping it (idempotent re-run)"
  log "To deliberately re-mint every secret: KIND_KV_RESEED=1 (destructive — see this script's header)"
  exit 0
elif [ "${#present[@]}" -ne 0 ]; then
  die "PARTIAL Vault KV seed under ${VAULT_KV_MOUNT}/${BRAND}/ — populated: ${present[*]}; missing: ${absent[*]}.
       That is an interrupted first run. Re-seeding would re-mint the populated paths, and any Postgres/Cassandra
       volume already initialized from them keeps the OLD password (the 'password authentication failed for user
       \"userbff\"' wedge). Pick one, deliberately:
         KIND_KV_RESEED=1 make kind-up      # re-mint everything (only with fresh/wiped volumes)
         make kind-down && make kind-up     # start clean"
else
  log "Vault KV is empty (none of: ${SENTINEL_PATHS[*]}) — seeding for the first time"
fi

log "Running ${SEEDER} (ONLINE mode via the vault PATH shim)"
bash "${SEEDER}" "$@"

# POST-CONDITION: the seeder is only "done" if the sentinels are now readable.
# Without this a seeder that failed to authenticate would leave the next run
# looking like a fresh first run forever.
still_absent=()
for p in "${SENTINEL_PATHS[@]}"; do
  kv_populated "${p}" || still_absent+=("${p}")
done
[ "${#still_absent[@]}" -eq 0 ] \
  || die "seeding reported success but these KV paths are still empty: ${still_absent[*]} (under ${VAULT_KV_MOUNT}/${BRAND}/)"
log "Vault KV seeded — ${#SENTINEL_PATHS[@]}/${#SENTINEL_PATHS[@]} sentinel path(s) verified readable"

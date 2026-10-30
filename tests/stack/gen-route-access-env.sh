#!/usr/bin/env bash
# gen-route-access-env.sh — create (never rotate) tests/stack/.route-access-db.env,
# the GITIGNORED file that holds the local stack's route-access-db OWNER password.
#
# WHY IT EXISTS. compose.local.yaml used to spell that password inline, in
# POSTGRES_PASSWORD and in all four gateways' ROUTE_ACCESS_R2DBC_URL, as the owner
# role's own name. The same word was also the cluster manifest's POSTGRES_PASSWORD
# from 2026-06-03 to 2026-06-10, so it is a published, guessable credential for a
# role that has DDL on the table that drives gateway RBAC. compose.local.yaml now
# reads ${ROUTE_ACCESS_DB_PASSWORD:-} and the Makefile's STACK_ENV threads it in
# from this file on every compose call (scripts/stack-up.ps1 does the same on
# Windows), so a fresh local stack gets a per-checkout random value.
#
# CREATE, NEVER ROTATE. The postgres image honours POSTGRES_PASSWORD only when it
# initialises an EMPTY data dir. `make stack-halt` -> `make stack-up` keeps the
# route-access-pg volume, so the password must stay what the volume was born with.
# An existing non-empty value in the file is therefore always kept. `make
# stack-down` (which drops the volumes) deletes the file, so the next stack-up
# initialises a fresh volume with a fresh value.
#
# A VOLUME OLDER THAN THIS FILE. When the file is missing but this compose
# project's route-access-pg volume already exists, the volume was initialised by
# the old compose file, i.e. with the owner role's name as the password. Minting
# a random value then would lock every gateway out of the route table (they fall
# back to the Cassandra cache and new route rows never land), so the generator
# ADOPTS the role name for that volume and says so on stderr, once. Rotate it
# with `make stack-down` (drops the stack's data) or by ALTER ROLE inside the
# container followed by editing this file. If the file was deleted while a volume
# minted from a RANDOM value still exists, the adopted value is wrong: restore
# the file or run `make stack-down`. When docker cannot answer at all (daemon
# down, wrong context) nothing is written and the run fails, rather than guess.
#
# URL-SAFE BY CONSTRUCTION. The value is interpolated into r2dbc URLs, which
# URL-decode the userinfo (a `+` becomes a space; see
# tests/scripts/test-url-embedded-credentials.sh), so it is hex, and a hand-edited
# value outside [A-Za-z0-9._~-] is refused rather than passed on.
#
# Usage: gen-route-access-env.sh            ensure the file exists (quiet when it does)
#        gen-route-access-env.sh --print    ensure, then print ONLY the value on stdout
#                                           (for STACK_ENV's command substitution;
#                                           make echoes the substitution, not the value)
# Env:   ROUTE_ACCESS_DB_ENV      the file (default tests/stack/.route-access-db.env)
#        ROUTE_ACCESS_DB_VOLUME   the volume to probe (default
#                                 ${COMPOSE_PROJECT_NAME:-hugmesh-local}_route-access-pg)
#        DOCKER                   the docker CLI (default docker)
# Guard: tests/stack/test-gen-route-access-env.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROUTE_ACCESS_DB_ENV:-${HERE}/.route-access-db.env}"
VOLUME="${ROUTE_ACCESS_DB_VOLUME:-${COMPOSE_PROJECT_NAME:-hugmesh-local}_route-access-pg}"
DOCKER="${DOCKER:-docker}"
KEY=ROUTE_ACCESS_DB_PASSWORD
# compose.local.yaml's POSTGRES_USER for route-access-db.
OWNER_ROLE=gateway

print=""
case "${1:-}" in
  --print) print=1 ;;
  "") ;;
  *) echo "gen-route-access-env.sh: unknown argument: $1" >&2; exit 2 ;;
esac

current() {
  [ -f "${ENV_FILE}" ] || return 0
  sed -n "s/^${KEY}=//p" "${ENV_FILE}" | tail -1
}

mint() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

# probe_volume -> 0 the volume exists, 1 it does not, 2 docker could not say.
# "Could not say" (daemon down, wrong context, permission) must not be read as
# "absent": a fresh value written then would lock an existing volume out.
probe_volume() {
  command -v "${DOCKER}" >/dev/null 2>&1 || return 1  # no docker CLI: no volume here
  local err
  if err="$("${DOCKER}" volume inspect "${VOLUME}" 2>&1 >/dev/null)"; then return 0; fi
  case "$(printf '%s' "${err}" | tr '[:upper:]' '[:lower:]')" in
    *"no such volume"*) return 1 ;;
  esac
  return 2
}

val="$(current)"
if [ -z "${val}" ]; then
  probe_volume && pv=0 || pv=$?
  if [ "${pv}" -eq 2 ]; then
    echo "gen-route-access-env.sh: docker could not say whether volume ${VOLUME} exists," >&2
    echo "  so ${ENV_FILE##*/} was NOT written (a new value would lock an existing volume's" >&2
    echo "  gateways out). Start docker, or check DOCKER_HOST / the docker context, and retry." >&2
    exit 1
  fi
  if [ "${pv}" -eq 0 ]; then
    val="${OWNER_ROLE}"
    how=adopted
    origin="adopted: volume ${VOLUME} predates this file (initialised by the old compose default)"
    {
      echo "WARNING: ${ENV_FILE##*/} was missing but volume ${VOLUME} exists."
      echo "         Keeping the password that volume was initialised with (the owner role's"
      echo "         name, the compose default before 2026-10-29) so the gateways still connect."
      echo "         Rotate it: 'make stack-down' (DROPS the stack's data) and the next"
      echo "         'make stack-up' mints a random one; or ALTER ROLE in the container and"
      echo "         edit ${ENV_FILE##*/} to match."
    } >&2
  else
    val="$(mint)"
    how=generated
    origin="generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  case "${val}" in
    ""|*[!A-Za-z0-9._~-]*) echo "gen-route-access-env.sh: could not produce a value" >&2; exit 1 ;;
  esac
  tmp="${ENV_FILE}.tmp.$$"
  ( umask 077
    { echo "# route-access-db owner password for the LOCAL compose stack only."
      echo "# GENERATED by tests/stack/gen-route-access-env.sh — gitignored, never commit."
      echo "# Must match what the route-access-pg volume was initialised with: do not"
      echo "# edit or delete it while that volume exists (make stack-down removes both)."
      echo "# ${origin}"
      printf '%s=%s\n' "${KEY}" "${val}"
    } > "${tmp}" )
  mv -f "${tmp}" "${ENV_FILE}"
  [ -n "${print}" ] || echo "==> Wrote ${ENV_FILE} (${how})"
fi

case "${val}" in
  *[!A-Za-z0-9._~-]*)
    echo "gen-route-access-env.sh: ${KEY} in ${ENV_FILE} holds a character that is not" >&2
    echo "  URL-unreserved; the r2dbc URL would decode it differently. Fix the file." >&2
    exit 1 ;;
esac

[ -z "${print}" ] || printf '%s' "${val}"

#!/usr/bin/env bash
# gen-route-access-env.sh — make sure tests/stack/.env holds the local stack's
# route-access-db OWNER password (ROUTE_ACCESS_DB_PASSWORD). Create, never rotate.
#
# WHY IT EXISTS. compose.local.yaml used to spell that password inline, in
# POSTGRES_PASSWORD and in all four gateways' ROUTE_ACCESS_R2DBC_URL, as the owner
# role's own name. The same word was also the cluster manifest's POSTGRES_PASSWORD
# from 2026-06-03 to 2026-06-10, so it is a published, guessable credential for a
# role that has DDL on the table that drives gateway RBAC. compose.local.yaml now
# reads ${ROUTE_ACCESS_DB_PASSWORD:-}, and a fresh checkout gets a random value.
#
# WHY tests/stack/.env. It is the file docker compose loads BY ITSELF for
# `-f tests/stack/compose.local.yaml`, from any working directory and with or
# without `-p hugmesh-local`. So every caller gets the value, not only the ones
# that know about it: `make stack-*`, the Studio's Mesh Monitor scale button
# (`docker compose -p hugmesh-local -f … up --scale`), a hand-run
# `docker compose -f tests/stack/compose.local.yaml up -d`. An empty value there
# makes every new gateway container fail to load the route table, which is RBAC.
# Two things defeat the auto-load, and the callers that hit them pass the value
# explicitly instead: any `--env-file X` (compose then skips .env for the main
# file; the Makefile's m2 registry adds one) and an EMPTY ROUTE_ACCESS_DB_PASSWORD
# exported in the shell (an environment variable beats .env, even when empty).
# The Makefile's STACK_ENV and the Studio's LocalStackNode._build_env both pass it.
#
# THE FILE IS SHARED, SO THIS SCRIPT OWNS ONE KEY, NOT THE FILE. An operator may
# keep their own compose overrides in tests/stack/.env. Every write keeps every
# other line as it is and only adds (or, with --remove, strips) this script's
# marked block and any ROUTE_ACCESS_DB_PASSWORD line. The file is made mode 0600
# because it now holds a credential, and it is gitignored.
#
# CREATE, NEVER ROTATE. The postgres image honours POSTGRES_PASSWORD only when it
# initialises an EMPTY data dir. `make stack-halt` -> `make stack-up` keeps the
# route-access-pg volume, so the password must stay what the volume was born with.
# A non-empty value already in the file is always kept. `make stack-down` and
# `make stack-clean` drop the volume and then run --remove, so the next stack-up
# initialises a fresh volume with a fresh value.
#
# WHEN THE KEY IS MISSING, where the value comes from (first match wins):
#   1. tests/stack/.route-access-db.env, the file an earlier revision of this script
#      wrote. Its value is moved into .env and the old file is deleted.
#   2. this compose project's route-access-pg volume EXISTS. A random value would
#      lock every gateway out of the route table, so the volume's value is adopted
#      and stderr says so:
#      a. from the project's route-access-db CONTAINER, running or stopped, when one
#         exists: its POSTGRES_PASSWORD is what compose last created it with. This is
#         what makes a SECOND checkout of the repo work against a stack the first
#         checkout started (see MULTIPLE CHECKOUTS below).
#      b. otherwise the owner role's name: every volume created before 2026-10-29
#         was initialised with it. If the volume was in fact initialised from a
#         random value (by another checkout, whose containers are gone), this guess
#         is WRONG; copy the key from that checkout's tests/stack/.env instead.
#   3. docker cannot answer (daemon down, wrong context): nothing is written and the
#      run fails, rather than guess.
#   4. no volume: a fresh random value (48 hex).
#
# MULTIPLE CHECKOUTS. compose.local.yaml and every file it includes say
# `name: hugmesh-local`, so all checkouts on one machine share ONE route-access-pg
# volume, while tests/stack/.env is per checkout. Case 2a covers a second checkout
# while the first one's containers exist. After `make stack-halt` (containers
# removed) it does not: copy ROUTE_ACCESS_DB_PASSWORD from the checkout that created
# the volume, or give the second checkout its own COMPOSE_PROJECT_NAME. A
# `make stack-down` in one checkout drops the shared volume and removes only ITS
# OWN key: the other checkouts keep a value for a volume that no longer exists, so
# their next stack-up initialises the new volume with that value (consistent, since
# only that checkout then holds it).
#
# URL-SAFE BY CONSTRUCTION. The value is interpolated into r2dbc URLs, which
# URL-decode the userinfo (a `+` becomes a space; see
# tests/scripts/test-url-embedded-credentials.sh), so it is hex, and a value outside
# [A-Za-z0-9._~-] (hand-edited, or adopted from a container) is refused rather than
# passed on.
#
# Usage: gen-route-access-env.sh            ensure the key exists (quiet when it does)
#        gen-route-access-env.sh --print    ensure, then print ONLY the value on stdout
#                                           (for STACK_ENV's command substitution;
#                                           make echoes the substitution, not the value)
#        gen-route-access-env.sh --remove   strip this script's block and key from the
#                                           file; delete the file if nothing else is left
# Env:   ROUTE_ACCESS_DB_ENV          the file (default tests/stack/.env)
#        ROUTE_ACCESS_DB_LEGACY_ENV   the old file (default tests/stack/.route-access-db.env)
#        ROUTE_ACCESS_DB_PROJECT      compose project (default ${COMPOSE_PROJECT_NAME:-hugmesh-local})
#        ROUTE_ACCESS_DB_VOLUME       the volume to probe (default <project>_route-access-pg)
#        DOCKER                       the docker CLI (default docker)
# Guard: tests/stack/test-gen-route-access-env.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROUTE_ACCESS_DB_ENV:-${HERE}/.env}"
LEGACY_FILE="${ROUTE_ACCESS_DB_LEGACY_ENV:-${HERE}/.route-access-db.env}"
PROJECT="${ROUTE_ACCESS_DB_PROJECT:-${COMPOSE_PROJECT_NAME:-hugmesh-local}}"
VOLUME="${ROUTE_ACCESS_DB_VOLUME:-${PROJECT}_route-access-pg}"
DOCKER="${DOCKER:-docker}"
KEY=ROUTE_ACCESS_DB_PASSWORD
# compose.local.yaml's POSTGRES_USER for route-access-db.
OWNER_ROLE=gateway
BEGIN_MARK="# >>> route-access-db owner password (tests/stack/gen-route-access-env.sh) >>>"
END_MARK="# <<< route-access-db owner password <<<"
ME=gen-route-access-env.sh

mode=ensure
case "${1:-}" in
  --print) mode=print ;;
  --remove) mode=remove ;;
  "") ;;
  *) echo "${ME}: unknown argument: $1" >&2; exit 2 ;;
esac

# read_key <file> -> the LAST value compose would read for KEY (dotenv: optional
# `export `, spaces around `=`, one pair of matching quotes), or nothing.
read_key() {
  [ -f "$1" ] || return 0
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?${KEY}[[:space:]]*=[[:space:]]*//p" "$1" \
    | tail -1 | sed -E -e 's/[[:space:]]+$//' -e "s/^\"(.*)\"\$/\\1/" -e "s/^'(.*)'\$/\\1/"
}

# without_key <file> -> the file's lines minus this script's block and any KEY line.
without_key() {
  [ -f "$1" ] || return 0
  awk -v b="${BEGIN_MARK}" -v e="${END_MARK}" -v k="${KEY}" '
    $0 == b { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    skip { next }
    $0 ~ "^[[:space:]]*(export[[:space:]]+)?" k "[[:space:]]*=" { next }
    { print }' "$1"
}

url_safe() { case "$1" in ""|*[!A-Za-z0-9._~-]*) return 1 ;; esac; }

# replace_file <content-file>: atomic, 0600, in the target's own directory.
replace_file() {
  local tmp
  tmp="${ENV_FILE}.tmp.$$"
  ( umask 077; cat "$1" > "${tmp}" )
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${ENV_FILE}"
}

if [ "${mode}" = remove ]; then
  [ -f "${ENV_FILE}" ] || exit 0
  rest="$(mktemp)"; trap 'rm -f "${rest}"' EXIT
  without_key "${ENV_FILE}" > "${rest}"
  if grep -q '[^[:space:]]' "${rest}"; then
    replace_file "${rest}"
    echo "==> Removed ${KEY} from ${ENV_FILE} (the operator's other lines kept)"
  else
    rm -f "${ENV_FILE}"
    echo "==> Removed ${ENV_FILE} (it held only ${KEY})"
  fi
  exit 0
fi

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

# container_password -> the POSTGRES_PASSWORD this project's route-access-db
# container (running or stopped) was created with, or nothing.
container_password() {
  local cid
  cid="$("${DOCKER}" ps -a -q \
    --filter "label=com.docker.compose.project=${PROJECT}" \
    --filter "label=com.docker.compose.service=route-access-db" 2>/dev/null)" || return 0
  cid="${cid%%$'\n'*}"
  [ -n "${cid}" ] || return 0
  "${DOCKER}" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${cid}" 2>/dev/null \
    | sed -n 's/^POSTGRES_PASSWORD=//p' | tail -1 || true
}

val="$(read_key "${ENV_FILE}")"
if [ -z "${val}" ]; then
  legacy="$(read_key "${LEGACY_FILE}")"
  if [ -n "${legacy}" ]; then
    val="${legacy}"
    how=migrated
    origin="migrated from ${LEGACY_FILE##*/} $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  else
    probe_volume && pv=0 || pv=$?
    if [ "${pv}" -eq 2 ]; then
      echo "${ME}: docker could not say whether volume ${VOLUME} exists," >&2
      echo "  so ${KEY} was NOT written to ${ENV_FILE} (a new value would lock an" >&2
      echo "  existing volume's gateways out). Start docker, or check DOCKER_HOST / the" >&2
      echo "  docker context, and retry." >&2
      exit 1
    fi
    if [ "${pv}" -eq 0 ]; then
      from_ctr="$(container_password)"
      if [ -n "${from_ctr}" ]; then
        val="${from_ctr}"
        how=adopted
        origin="adopted from the existing ${PROJECT} route-access-db container (volume ${VOLUME} predates this file)"
        {
          echo "WARNING: ${KEY} was missing from ${ENV_FILE##*/} but volume ${VOLUME} exists."
          echo "         Adopted the password the existing route-access-db container was"
          echo "         created with, so the gateways still connect."
        } >&2
      else
        val="${OWNER_ROLE}"
        how=adopted
        origin="adopted: volume ${VOLUME} predates this file and has no container (assumed the pre-2026-10-29 compose default)"
        {
          echo "WARNING: ${KEY} was missing from ${ENV_FILE##*/} but volume ${VOLUME} exists"
          echo "         and no route-access-db container is left to read its password from."
          echo "         Assuming the compose default before 2026-10-29 (the owner role's name)."
          echo "         If ANOTHER checkout created this volume, that guess is wrong: copy"
          echo "         ${KEY} from that checkout's tests/stack/.env into this one."
        } >&2
      fi
      {
        echo "         Rotate it: 'make stack-down' (DROPS the stack's data) and the next"
        echo "         'make stack-up' mints a random one; or ALTER ROLE in the container and"
        echo "         edit ${ENV_FILE##*/} to match."
      } >&2
    else
      val="$(mint)"
      how=generated
      origin="generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
  fi
  if ! url_safe "${val}"; then
    echo "${ME}: the ${how} value for ${KEY} is empty or not URL-unreserved;" >&2
    echo "  the r2dbc URL would decode it differently. Nothing was written." >&2
    exit 1
  fi
  merged="$(mktemp)"; trap 'rm -f "${merged}"' EXIT
  { without_key "${ENV_FILE}"
    echo "${BEGIN_MARK}"
    echo "# GENERATED, gitignored, never commit. Must match what the route-access-pg volume"
    echo "# was initialised with: do not edit or delete it while that volume exists"
    echo "# (make stack-down removes both). Other lines in this file are yours and are kept."
    echo "# ${origin}"
    printf '%s=%s\n' "${KEY}" "${val}"
    echo "${END_MARK}"
  } > "${merged}"
  replace_file "${merged}"
  [ "${how}" != migrated ] || rm -f "${LEGACY_FILE}"
  [ "${mode}" = print ] || echo "==> Wrote ${KEY} to ${ENV_FILE} (${how})"
fi

if ! url_safe "${val}"; then
  echo "${ME}: ${KEY} in ${ENV_FILE} holds a character that is not" >&2
  echo "  URL-unreserved; the r2dbc URL would decode it differently. Fix the file." >&2
  exit 1
fi
# The value is there and valid; keep a credential-bearing file private even when
# the operator created it with a wider mode.
chmod 600 "${ENV_FILE}" 2>/dev/null || true

[ "${mode}" != print ] || printf '%s' "${val}"

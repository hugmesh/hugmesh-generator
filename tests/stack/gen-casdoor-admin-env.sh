#!/usr/bin/env bash
# gen-casdoor-admin-env.sh — make sure tests/stack/.env holds the password the local
# stack's Casdoor built-in admin should have (CASDOOR_ADMIN_PASSWORD). Create, never
# rotate.
#
# WHY IT EXISTS (NEW-15). casbin/casdoor gives the built-in admin (built-in/admin) a
# public factory-default password when it bootstraps an empty database, and nothing on
# the compose lane ever changed it: tests/stack/seed-e2e.sh and derive-games-admin.sh
# both DEFAULTED to that value. With Casdoor published on every host interface, any
# machine on the LAN could sign in to the local mesh's identity provider as its admin.
# The cluster never had this gap (specs/cluster/manifests/casdoor/init-job.yaml moves the
# admin onto the Vault value and proves the default no longer logs in); this script plus
# seed-e2e.sh's casdoor_admin_session() is the compose twin of that step:
#   * this script mints ONE random value per checkout into the gitignored, 0600
#     tests/stack/.env (the file gen-stack-db-env.sh / gen-route-access-env.sh share);
#   * seed-e2e.sh signs in with it, and when it does not work yet but the factory
#     default still does (a FRESH Casdoor volume, or the operator's existing stack the
#     first time it is seeded after this change) moves the admin onto it with
#     /api/set-password and proves the default is refused afterwards;
#   * derive-games-admin.sh only READS it (--read): it never mints or rotates.
# No script spells a default for the admin password any more; the factory value
# appears only as the named bootstrap credential seed-e2e.sh takes the account over
# with. Guard: tests/scripts/test-stack-idp-exposure.sh.
#
# NOT TIED TO A VOLUME, unlike the DB passwords. Casdoor never reads this value: the
# admin's password lives in Casdoor's own database and only moves through
# /api/set-password. So there is nothing to adopt from a container, and a fresh value
# is always safe to mint: the next seed moves a factory-default admin onto it. The key
# survives `make stack-down` on purpose: the next stack's fresh Casdoor volume is
# moved onto the same value by its first seed, and tests/stack/up-real.sh's
# hugmesh-real project reads the same file.
#
# THE ONE CASE IT CANNOT FIX: a Casdoor whose admin was already moved onto a value this
# file no longer holds (the file was deleted, or this is a second checkout). The seed
# then refuses rather than guess (neither value signs in) and names the two ways out:
# put the old value back in the file (or export CASDOOR_ADMIN_PASS), or `make
# stack-down` (DROPS the stack's data) for a fresh Casdoor.
#
# THE FILE IS SHARED, SO THIS SCRIPT OWNS ONE KEY, NOT THE FILE. Every write keeps every
# other line and only replaces this script's marked block and any CASDOOR_ADMIN_PASSWORD
# line. The file is made 0600. A SYMLINKED .env stays a symlink (its target is replaced
# atomically in the target's own directory).
#
# The value is 48 hex characters. A hand-edited value must stay within
# [A-Za-z0-9._~-] (dotenv and form-encoding safe) and must not be the factory default;
# either is refused rather than passed on.
#
# Usage: gen-casdoor-admin-env.sh           ensure the key exists (quiet when it does)
#        gen-casdoor-admin-env.sh --print   ensure, then print ONLY the value on stdout
#        gen-casdoor-admin-env.sh --read    READ ONLY: print the value if the file holds
#                                           one, else nothing; never writes
# Env:   CASDOOR_ADMIN_ENV_FILE   the file (default tests/stack/.env)
# Never prints the value except on stdout for --print / --read.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CASDOOR_ADMIN_ENV_FILE:-${HERE}/.env}"
KEY=CASDOOR_ADMIN_PASSWORD
# casbin/casdoor's factory default for the built-in admin of an empty database. Public
# knowledge (upstream docs, and specs/cluster/manifests/casdoor/init-job.yaml's
# CASDOOR_BOOTSTRAP_PASSWORD); here ONLY so a hand-edited file holding it is refused.
FACTORY_DEFAULT="123"
BEGIN_MARK="# >>> local stack Casdoor admin password (tests/stack/gen-casdoor-admin-env.sh) >>>"
END_MARK="# <<< local stack Casdoor admin password <<<"
ME=gen-casdoor-admin-env.sh

# A symlinked env file: every write goes to the link's TARGET, so the link survives.
if [ -L "${ENV_FILE}" ]; then
  target="$(readlink -f -- "${ENV_FILE}" 2>/dev/null)" || target=""
  if [ -z "${target}" ] || [ ! -d "$(dirname -- "${target}")" ]; then
    echo "${ME}: ${ENV_FILE} is a symlink whose target directory does not exist;" >&2
    echo "  fix or remove the link and retry. Nothing was written." >&2
    exit 1
  fi
  ENV_FILE="${target}"
fi

mode=ensure
case "${1:-}" in
  --print) mode=print ;;
  --read) mode=read ;;
  "") ;;
  *) echo "${ME}: unknown argument: $1" >&2; exit 2 ;;
esac

# read_key <file> -> the LAST value a dotenv reader would take for KEY (optional
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

# usable <value> -> 0 when the value may be handed to the seed.
usable() {
  case "$1" in ""|*[!A-Za-z0-9._~-]*) return 1 ;; esac
  [ "$1" != "${FACTORY_DEFAULT}" ]
}

refuse_file_value() {
  echo "${ME}: ${KEY} in ${ENV_FILE} is Casdoor's factory default, or holds a character" >&2
  echo "  outside [A-Za-z0-9._~-]. Delete that line and re-run (a fresh value is minted)," >&2
  echo "  or put a value of your own there. Nothing was written." >&2
  exit 1
}

replace_file() { # <content-file>: atomic, 0600, in the target's own directory
  local tmp
  tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
  ( umask 077; cat "$1" > "${tmp}" ) || { rm -f "${tmp}"; return 1; }
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${ENV_FILE}"
}

mint() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

val="$(read_key "${ENV_FILE}")"

if [ "${mode}" = read ]; then
  [ -n "${val}" ] || exit 0
  usable "${val}" || refuse_file_value
  printf '%s' "${val}"
  exit 0
fi

if [ -z "${val}" ]; then
  val="$(mint)"
  usable "${val}" || { echo "${ME}: could not mint a value (openssl / od). Nothing was written." >&2; exit 1; }
  merged="$(mktemp "${TMPDIR:-/tmp}/${ME}.XXXXXX")"
  trap 'rm -f "${merged}"' EXIT
  { without_key "${ENV_FILE}"
    echo "${BEGIN_MARK}"
    echo "# GENERATED, gitignored, never commit. The local stack's Casdoor built-in admin"
    echo "# (built-in/admin) password: \`make stack-seed\` moves a Casdoor still on the"
    echo "# upstream factory default onto it. If you delete it while a seeded Casdoor"
    echo "# volume exists, put the old value back (or \`make stack-down\`, which drops the"
    echo "# data). Other lines in this file are yours and are kept."
    echo "# generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s=%s\n' "${KEY}" "${val}"
    echo "${END_MARK}"
  } > "${merged}"
  replace_file "${merged}"
  echo "==> Wrote ${KEY} to ${ENV_FILE} (generated; the next seed moves the Casdoor admin onto it)" >&2
elif ! usable "${val}"; then
  refuse_file_value
fi

# Keep a credential-bearing file private even when the operator created it wider.
# ENV_FILE is the link's target when the configured path is a symlink.
chmod 600 "${ENV_FILE}" 2>/dev/null || true

[ "${mode}" != print ] || printf '%s' "${val}"

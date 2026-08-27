#!/usr/bin/env bash
# e2e-password.sh — the ONE generator for the random-per-run e2e test password.
#
# WHY THIS FILE EXISTS. Every e2e-identity seeder in this repo used to mirror the
# same chain: per-user $E2E_<ROLE>_PASSWORD -> shared $E2E_PASSWORD -> the literal
# "e2e-pass". No CI lane anywhere ever set $E2E_PASSWORD, so every lane landed on
# the literal — a guessable, world-known password seeded into every local mesh,
# every kind cluster, and every QEMU-booted node this repo produces.
#
# The fix: GENERATE a fresh CSPRNG value the first time any run needs one, PERSIST
# it to a run-state file, and have every other process in that same run LOAD it
# from there instead of re-deriving or (worse) re-defaulting. Precedence:
#
#   1. an explicit $E2E_PASSWORD already in the environment  (operator override,
#      or same-run propagation — e.g. seed-e2e.sh exporting it into the
#      seed-accounts.sh subprocess it launches)
#   2. the run-state credentials file (written by whichever process in this run
#      needed a password FIRST)
#   3. GENERATE a fresh value, persist it, export it.
#
# seed-e2e.sh (compose), tests/qemu/seed-accounts.sh (QEMU + kind), and
# specs/cluster/bootstrap/kind-local/bootstrap-kind.sh (kind) are SEPARATE
# PROCESSES that can each be the "first" one to run in a given lane, and they
# MUST all end up with the SAME password — that is the entire point of step 2.
# Each of them sources this file and calls e2e_password_ensure(); none of them
# re-implements generation.
#
# CONSUMERS (Playwright/TypeScript, the mock BFF, pentest personas, …) do the
# opposite: they resolve from env or the credentials file and THROW when neither
# is available. They never call e2e_password_ensure() and never generate — a
# consumer inventing its own fallback is the exact bug this file exists to
# remove (see the contract's Rule 4).
#
# USAGE
#   Sourced (the normal case — defines the function, does NOT run it):
#     # shellcheck source=./e2e-password.sh
#     . "${HERE}/e2e-password.sh"
#     e2e_password_ensure   # sets + exports E2E_PASSWORD
#
#   Executed directly (for the Makefile banner / ad-hoc inspection): resolves
#   E2E_PASSWORD exactly as above and prints it, alone, to stdout:
#     bash tests/stack/e2e-password.sh
#
# ENV
#   E2E_PASSWORD          explicit override; highest precedence; propagated
#                          (not regenerated) if already set.
#   E2E_CREDENTIALS_FILE  default <repo-root>/.e2e-credentials — the run-state
#                          file. Plain KEY=value lines, no quotes, no `export`
#                          keyword, so it loads with `set -a; . file; set +a`
#                          AND with `docker compose --env-file`. Written with
#                          mode 600. Gitignored — NEVER commit a real value.
set -uo pipefail  # no -e: this file is sourced into callers with their own settings

E2E_PASSWORD_SCRIPT_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_PASSWORD_REPO_ROOT="$(cd "${E2E_PASSWORD_SCRIPT_HERE}/../.." && pwd)"
E2E_CREDENTIALS_FILE="${E2E_CREDENTIALS_FILE:-${E2E_PASSWORD_REPO_ROOT}/.e2e-credentials}"

# Fresh CSPRNG value. openssl first (present on every dev box + CI image this
# repo targets); a /dev/urandom + tr fallback for the rare box without it.
# Deliberately NEVER $RANDOM (17-bit, seeded from PID+time on some shells),
# NEVER date, NEVER a PID — none of those are unpredictable enough for a
# password seeded into a real Casdoor/Matrix/Mastodon account.
e2e_password_generate() {
  local val=""
  if command -v openssl >/dev/null 2>&1; then
    val="$(openssl rand -base64 24 2>/dev/null | tr -d '\n/+=')"
  fi
  if [ -z "${val}" ]; then
    val="$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 32)"
  fi
  if [ -z "${val}" ]; then
    echo "e2e-password.sh: could not generate a random password (no openssl, no /dev/urandom)" >&2
    return 1
  fi
  printf '%s' "${val}"
}

# Read one KEY from the credentials file. Empty stdout (rc 0) when the file or
# the key is absent — callers treat "empty" and "absent" identically, exactly
# like the per-user env-override checks elsewhere in this repo's seeders.
e2e_password_read() {  # <key>
  local key="$1"
  [ -f "${E2E_CREDENTIALS_FILE}" ] || return 0
  awk -F= -v k="${key}" '$1==k { sub(/^[^=]*=/, ""); print }' \
    "${E2E_CREDENTIALS_FILE}" 2>/dev/null | tail -n1
}

# Merge one KEY=value into the credentials file (replacing any prior line for
# that key), mode 600. Rewrite-via-tempfile-then-rename so a reader never sees
# a half-written file.
e2e_password_write() {  # <key> <value>
  local key="$1" val="$2" dir tmp
  dir="$(dirname "${E2E_CREDENTIALS_FILE}")"
  mkdir -p "${dir}" 2>/dev/null || true
  ( umask 077
    tmp="$(mktemp "${E2E_CREDENTIALS_FILE}.XXXXXX")" || exit 1
    if [ -f "${E2E_CREDENTIALS_FILE}" ]; then
      grep -v "^${key}=" "${E2E_CREDENTIALS_FILE}" > "${tmp}" 2>/dev/null || true
    fi
    printf '%s=%s\n' "${key}" "${val}" >> "${tmp}" || { rm -f "${tmp}"; exit 1; }
    chmod 600 "${tmp}" || { rm -f "${tmp}"; exit 1; }
    mv -f "${tmp}" "${E2E_CREDENTIALS_FILE}" || { rm -f "${tmp}"; exit 1; }
  )
}

# The one entry point every generating process calls. Sets + exports
# E2E_PASSWORD in THIS shell and, on the generate path, persists it for every
# other process in the same run to load.
e2e_password_ensure() {
  # 1. Already set in the environment (operator override, or a parent process
  #    in this same run already resolved/exported it) — highest precedence,
  #    never overwritten.
  if [ -n "${E2E_PASSWORD:-}" ]; then
    export E2E_PASSWORD
    return 0
  fi
  # 2. The run-state file — whichever process needed a password FIRST wrote it.
  local from_file
  from_file="$(e2e_password_read E2E_PASSWORD)"
  if [ -n "${from_file}" ]; then
    E2E_PASSWORD="${from_file}"
    export E2E_PASSWORD
    return 0
  fi
  # 3. Nobody has one yet in this run: generate, persist, export.
  local generated
  generated="$(e2e_password_generate)" || return 1

  # PERSISTING IS NOT OPTIONAL, so its failure is fatal rather than ignored.
  # Every other process in this run resolves via step 2 — if the write silently
  # failed, the NEXT process would find no file, generate a DIFFERENT password,
  # and seed identities the first process cannot log in as. A loud failure here
  # is the only thing standing between that and a run that looks fine until an
  # unrelated assertion fails much later.
  if ! e2e_password_write "E2E_PASSWORD" "${generated}"; then
    echo "e2e-password.sh: generated a password but could NOT write it to" >&2
    echo "  ${E2E_CREDENTIALS_FILE}" >&2
    echo "  Every other process in this run resolves from that file, so continuing" >&2
    echo "  would give them a different password. Set E2E_CREDENTIALS_FILE to a" >&2
    echo "  writable path, or export E2E_PASSWORD yourself to skip generation." >&2
    return 1
  fi

  # POSITIVE POST-CONDITION: read it back rather than trusting the write. The
  # writer reporting on its own work is not evidence that a later process will
  # find the same value.
  local readback
  readback="$(e2e_password_read E2E_PASSWORD)"
  if [ "${readback}" != "${generated}" ]; then
    echo "e2e-password.sh: wrote E2E_PASSWORD to ${E2E_CREDENTIALS_FILE} but read" >&2
    echo "  back a different value. Refusing to continue with a password other" >&2
    echo "  processes in this run will not resolve to." >&2
    return 1
  fi

  E2E_PASSWORD="${generated}"
  export E2E_PASSWORD
}

# Executed directly (not sourced): resolve and print E2E_PASSWORD, nothing else
# on stdout. Sourcing this file never does this — it only defines the functions
# above, so a sourcing caller controls exactly when generation happens.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  e2e_password_ensure
  printf '%s\n' "${E2E_PASSWORD}"
fi

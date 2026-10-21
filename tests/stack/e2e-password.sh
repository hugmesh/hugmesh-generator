#!/usr/bin/env bash
# e2e-password.sh — the ONE generator for the random-per-run e2e test password.
#
# WHY THIS FILE EXISTS. Every e2e-identity seeder in this repo used to mirror the
# same chain: per-user $E2E_<ROLE>_PASSWORD -> shared $E2E_PASSWORD -> the literal
# "e2e-pass". No CI lane anywhere ever set $E2E_PASSWORD, so every lane landed on
# the literal — a guessable, world-known password seeded into every local mesh,
# every kind cluster, and every QEMU-booted node this repo produces.
#
# The fix: GENERATE a fresh CSPRNG value at the START OF EVERY RUN, PERSIST it to
# a run-state file, and have every other process in that same run LOAD it from
# there instead of re-deriving or (worse) re-defaulting.
#
# WHERE A RUN STARTS (the rotation boundary — e2e_password_start_run() below).
# A run starts when a lane SEEDS its identity stores, and exactly one process per
# lane does that:
#
#   compose  tests/stack/seed-e2e.sh                       (make stack-seed)
#   kind     specs/cluster/bootstrap/kind-local/bootstrap-kind.sh  (make kind-up)
#   QEMU     tests/qemu/run-qemu-e2e.sh, run mode         (make e2e)
#
# Each of those calls e2e_password_start_run(), which MINTS a new value every
# time (until 2026-10-15 nothing ever did: the chain reused the file's value
# forever, so one password written on 2026-08-27 served every run after it).
# The seeders then RECONCILE every stored e2e identity to it — Casdoor via the
# apply hook's set-password (tests/qemu/seed-accounts.sh), the compose tuwunel
# users via a self-service change from E2E_PASSWORD_PREVIOUS (seed-e2e.sh leg 2) —
# so a persisted volume does not 401 after a rotation.
#
# Everything else in the run must NOT rotate. Precedence for them
# (e2e_password_ensure()):
#
#   1. an explicit $E2E_PASSWORD already in the environment  (operator override,
#      or same-run propagation — e.g. seed-e2e.sh exporting it into the
#      seed-accounts.sh subprocess it launches)
#   2. the run-state credentials file (written by the process that started the
#      run, or by whichever process needed a password FIRST on a tree that never
#      had one)
#   3. GENERATE a fresh value, persist it, export it.
#
# Sub-seeders (tests/qemu/seed-accounts.sh standalone, tests/api/test-bff-admin.sh,
# the mock lane's tests/stack/up.sh) call e2e_password_ensure(); none of them
# re-implements generation. The mock lane (up.sh) deliberately does NOT rotate:
# its BFF holds no stored identity, and rotating there would only re-password the
# file a running compose or kind mesh was seeded from.
#
# OPT-OUT: E2E_PASSWORD_KEEP=1 makes e2e_password_start_run() behave exactly like
# e2e_password_ensure() — reuse the file's value — for debugging against a mesh
# whose password you want to keep. An explicit $E2E_PASSWORD also keeps (and is
# never written to the file). The Studio's "Add user" and its saved-mesh restore
# pass E2E_PASSWORD_KEEP=1: adding one account must not re-password every other.
# (`make e2e` runs the QEMU lane via plain `sudo`, which resets the environment:
# the opt-outs reach it only from a root shell, `sudo -E`, or `docker run -e`.)
#
# ONE FILE, EVERY LANE. The default file belongs to the most recent run start in
# ANY lane: `make kind-up` or `make e2e` re-passwords the file a running compose
# mesh was seeded from. Re-run `make stack-seed` (it reconciles) or start the
# other run with E2E_PASSWORD_KEEP=1.
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
#   The run-start process of a lane (see WHERE A RUN STARTS) instead calls:
#     e2e_password_start_run   # mints + persists + exports a NEW value
#
#   Executed directly (for the Makefile banner / ad-hoc inspection): resolves
#   E2E_PASSWORD exactly as e2e_password_ensure() does — it NEVER rotates, so
#   inspecting the value cannot re-password a live mesh — and prints it, alone,
#   to stdout:
#     bash tests/stack/e2e-password.sh
#
# ENV
#   E2E_PASSWORD          explicit override; highest precedence; propagated
#                          (not regenerated) if already set.
#   E2E_PASSWORD_KEEP     1 = do not rotate at the run start (debugging opt-out).
#   E2E_PASSWORD_HISTORY  how many superseded values E2E_PASSWORD_PREVIOUS keeps
#                          (default 5). The file then also holds
#                          E2E_PASSWORD_PREVIOUS=<newest>,<older>,... so the
#                          compose tuwunel users can be moved off an old value.
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
  # EXACTLY 32 alphanumeric characters, every time. The old recipe stripped
  # `/+=` out of `openssl rand -base64 24` (32 chars) AFTER the fact, so about
  # two values in three came out SHORTER than 32 — the operator's own file held
  # a 28-char value. Over-generate (48 bytes -> 64 base64 chars, ~60 of them
  # alphanumeric), keep only [A-Za-z0-9], cut to 32, and refuse anything short.
  # Alphanumeric-only is load-bearing: the value travels unquoted through
  # `set -a; . file`, `docker compose --env-file`, JSON bodies and the
  # comma-joined E2E_PASSWORD_PREVIOUS list below.
  local val=""
  if command -v openssl >/dev/null 2>&1; then
    val="$(openssl rand -base64 48 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 32)"
  fi
  if [ "${#val}" -ne 32 ]; then
    val="$(head -c 256 /dev/urandom 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 32)"
  fi
  if [ "${#val}" -ne 32 ]; then
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
  # PRESENT BUT UNREADABLE IS NOT "ABSENT". `make e2e` drives the QEMU harness
  # under sudo, and seed-accounts.sh then writes this file as ROOT, mode 600, at
  # the repo root. Every later non-root run can stat it but not read it.
  #
  # Without this branch, awk exits 2 (EACCES) with its message sent to
  # /dev/null, `pipefail` propagates that 2 through the `| tail -n1`, and the
  # caller's `local x="$(...)"` inherits it — so a caller under `set -e` dies
  # with rc=2 and NO output at all. Silence is the worst possible answer here:
  # regenerating would be wrong (the value other processes already hold is in
  # that file), and proceeding would diverge.
  if [ ! -r "${E2E_CREDENTIALS_FILE}" ]; then
    echo "e2e-password.sh: ${E2E_CREDENTIALS_FILE} exists but is not readable by" >&2
    echo "  $(id -un) (owner $(stat -c '%U' "${E2E_CREDENTIALS_FILE}" 2>/dev/null || echo '?'), mode $(stat -c '%a' "${E2E_CREDENTIALS_FILE}" 2>/dev/null || echo '?'))." >&2
    echo "  A sudo run (make e2e drives QEMU as root) writes it root-owned 0600." >&2
    echo "  Fix: sudo chown $(id -un) ${E2E_CREDENTIALS_FILE}   (or delete it and re-seed)." >&2
    return 1
  fi
  awk -F= -v k="${key}" '$1==k { sub(/^[^=]*=/, ""); print }' \
    "${E2E_CREDENTIALS_FILE}" 2>/dev/null | tail -n1
}

# Merge KEY=value pairs into the credentials file (replacing any prior line for
# each key), mode 600, in ONE rename — so a reader never sees a half-written file
# and never sees a new E2E_PASSWORD beside a stale E2E_PASSWORD_PREVIOUS.
#
# Two refusals and one ownership rule, all for the same reason: this file is
# shared by every lane, and a write that silently loses it is worse than none.
#   * PRESENT BUT UNREADABLE -> refuse. The merge would otherwise read nothing
#     (grep's error discarded), drop every other key, and replace a file it
#     could not see.
#   * OWNERSHIP IS KEPT. The QEMU lane runs as root (`make e2e` uses $(SUDO), the
#     containerized route runs as root in the container). A root rewrite would
#     leave a root-owned 0600 file that every later non-root run cannot read. So
#     a root writer copies the existing file's owner onto the new one, or — when
#     there is no file yet and it runs under sudo — hands it to $SUDO_UID.
e2e_password_write() {  # <key> <value> [<key> <value> ...]
  local dir
  if [ $(( $# % 2 )) -ne 0 ] || [ $# -eq 0 ]; then
    echo "e2e-password.sh: e2e_password_write needs KEY VALUE pairs" >&2
    return 1
  fi
  if [ -e "${E2E_CREDENTIALS_FILE}" ] && [ ! -r "${E2E_CREDENTIALS_FILE}" ]; then
    e2e_password_read E2E_PASSWORD >/dev/null   # prints the named-fix message
    return 1
  fi
  dir="$(dirname "${E2E_CREDENTIALS_FILE}")"
  mkdir -p "${dir}" 2>/dev/null || true
  ( umask 077
    tmp="$(mktemp "${E2E_CREDENTIALS_FILE}.XXXXXX")" || exit 1
    trap 'rm -f "${tmp}" "${tmp}.n"' EXIT
    if [ -f "${E2E_CREDENTIALS_FILE}" ]; then
      cp "${E2E_CREDENTIALS_FILE}" "${tmp}" || exit 1
    fi
    while [ $# -gt 0 ]; do
      k="$1" v="$2"; shift 2
      awk -F= -v k="${k}" '$1!=k' "${tmp}" > "${tmp}.n" || exit 1
      printf '%s=%s\n' "${k}" "${v}" >> "${tmp}.n" || exit 1
      mv -f "${tmp}.n" "${tmp}" || exit 1
    done
    chmod 600 "${tmp}" || exit 1
    if [ "$(id -u)" -eq 0 ]; then
      if [ -f "${E2E_CREDENTIALS_FILE}" ]; then
        chown --reference="${E2E_CREDENTIALS_FILE}" "${tmp}" 2>/dev/null || true
      elif [ -n "${SUDO_UID:-}" ]; then
        chown "${SUDO_UID}:${SUDO_GID:-${SUDO_UID}}" "${tmp}" 2>/dev/null || true
      fi
    fi
    mv -f "${tmp}" "${E2E_CREDENTIALS_FILE}" || exit 1
    trap - EXIT
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
  from_file="$(e2e_password_read E2E_PASSWORD)" || return 1
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

# How many superseded values E2E_PASSWORD_PREVIOUS keeps (newest first).
E2E_PASSWORD_HISTORY="${E2E_PASSWORD_HISTORY:-5}"

# THE RUN BOUNDARY. Called by exactly one process per lane — the one that STARTS
# a run by seeding that lane's identity stores — and by nothing else:
#
#   compose  tests/stack/seed-e2e.sh                 (make stack-seed)
#   kind     specs/cluster/bootstrap/kind-local/bootstrap-kind.sh (make kind-up)
#   QEMU     tests/qemu/run-qemu-e2e.sh, run mode   (make e2e)
#
# It MINTS a fresh value, persists it atomically (mode 600) and exports it, so
# every child of that process inherits it via env and every later process of the
# same run (tests/e2e/run.sh, the Playwright helpers, mock-bff, the shot harness)
# READS it from the file. Sub-seeders (tests/qemu/seed-accounts.sh, the pentest
# personas seeder) and consumers keep calling e2e_password_ensure() / reading the
# file: rotating there would split one run across two passwords.
#
# Precedence, highest first:
#   1. $E2E_PASSWORD already in the environment — an operator override, or a
#      parent in this same run that already started it. Kept, never written.
#   2. E2E_PASSWORD_KEEP=1 — the debugging opt-out: behaves exactly like
#      e2e_password_ensure() (reuse the file's value; mint only when absent).
#   3. Otherwise ROTATE: mint, persist, read back, export. The superseded value
#      is kept in E2E_PASSWORD_PREVIOUS (comma-separated, newest first, at most
#      $E2E_PASSWORD_HISTORY) for the one kind of store that cannot be reset with
#      an admin credential — the compose tuwunel's e2e users, which change their
#      own password with the old one (seed-e2e.sh leg 2). Every store the seeders
#      CAN reset (Casdoor, via the apply hook's set-password reconcile) is simply
#      set to the new value.
#
# The file is shared by every lane: a run started in one lane re-passwords the
# file another lane's still-running mesh was seeded from. Re-run that lane's
# seeder (it reconciles), or start the other run with E2E_PASSWORD_KEEP=1.
e2e_password_start_run() {
  if [ -n "${E2E_PASSWORD:-}" ]; then
    export E2E_PASSWORD
    return 0
  fi
  if [ "${E2E_PASSWORD_KEEP:-0}" = "1" ]; then
    e2e_password_ensure
    return $?
  fi
  local old prev generated readback hist="" n=0 v
  old="$(e2e_password_read E2E_PASSWORD)" || return 1
  prev="$(e2e_password_read E2E_PASSWORD_PREVIOUS)" || return 1
  generated="$(e2e_password_generate)" || return 1
  # Newest first, de-duplicated, never the new value, capped.
  for v in ${old} ${prev//,/ }; do
    [ -n "${v}" ] && [ "${v}" != "${generated}" ] || continue
    case ",${hist}," in *",${v},"*) continue ;; esac
    [ "${n}" -lt "${E2E_PASSWORD_HISTORY}" ] || break
    hist="${hist:+${hist},}${v}"; n=$((n + 1))
  done
  if ! e2e_password_write E2E_PASSWORD "${generated}" E2E_PASSWORD_PREVIOUS "${hist}"; then
    echo "e2e-password.sh: could NOT write this run's new password to" >&2
    echo "  ${E2E_CREDENTIALS_FILE}" >&2
    echo "  Refusing to start the run: every later process resolves from that file." >&2
    echo "  Fix the file, or set E2E_PASSWORD_KEEP=1 / E2E_PASSWORD to skip rotation." >&2
    return 1
  fi
  readback="$(e2e_password_read E2E_PASSWORD)"
  if [ "${readback}" != "${generated}" ]; then
    echo "e2e-password.sh: rotated E2E_PASSWORD in ${E2E_CREDENTIALS_FILE} but read back" >&2
    echo "  a different value. Refusing to start a run other processes will not join." >&2
    return 1
  fi
  E2E_PASSWORD="${generated}"
  export E2E_PASSWORD
}

# THE SEED STAMP — "a seed reconciled the identity store to THIS file".
#
# The run start rewrites the file BEFORE seeding, so the file alone cannot say
# whether the identities hold its value: a seed that died after the rotation leaves
# them on the previous one. Only the compose seeder (tests/stack/seed-e2e.sh) calls
# this, and only once its identity leg is VERIFIED (and again when the whole seed
# completes). It writes ${E2E_CREDENTIALS_FILE}.seeded (mode 600, KEY=value):
#
#   E2E_SEEDED_SHA256  sha256 of the credentials file the identities now match
#   E2E_SEEDED_AT      epoch seconds the stage completed
#   E2E_SEEDED_STAGE   identities | complete
#
# A hash of the FILE, never of a password, and never a value. Readers (the Studio's
# saved-mesh warm start and its credentials check, studio/hugmesh_studio/core/
# credentials_truth.py seed_stamp) trust the stamp only while the sha256 still
# equals the file on disk: any later rewrite (another lane's run start, a
# saved-mesh put-back) silently invalidates it.
#
# When the value this process seeded is NOT the file's (an explicit E2E_PASSWORD
# override, or another lane rotated the file mid-seed) the stamp is REMOVED instead:
# a stale stamp vouching for the file would be the exact lie it exists to prevent.
e2e_password_seed_stamp_path() { printf '%s' "${E2E_CREDENTIALS_FILE}.seeded"; }
e2e_password_stamp_seeded() {  # <stage>
  local stage="${1:-complete}" stamp file_val sha
  stamp="$(e2e_password_seed_stamp_path)"
  file_val="$(e2e_password_read E2E_PASSWORD 2>/dev/null)" || file_val=""
  if [ -z "${E2E_PASSWORD:-}" ] || [ "${file_val}" != "${E2E_PASSWORD}" ]; then
    rm -f "${stamp}" 2>/dev/null || true
    echo "e2e-password.sh: seed stamp NOT written — this seed's password is not the one in ${E2E_CREDENTIALS_FILE} (explicit E2E_PASSWORD, or the file was rotated since)" >&2
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha="$(sha256sum < "${E2E_CREDENTIALS_FILE}" | cut -d' ' -f1)"
  else
    sha="$(openssl dgst -sha256 -r < "${E2E_CREDENTIALS_FILE}" | cut -d' ' -f1)"
  fi
  if [ "${#sha}" -ne 64 ]; then
    rm -f "${stamp}" 2>/dev/null || true
    echo "e2e-password.sh: seed stamp NOT written — could not hash ${E2E_CREDENTIALS_FILE}" >&2
    return 1
  fi
  E2E_CREDENTIALS_FILE="${stamp}" e2e_password_write \
    E2E_SEEDED_SHA256 "${sha}" E2E_SEEDED_AT "$(date +%s)" E2E_SEEDED_STAGE "${stage}"
}

# Executed directly (not sourced): resolve and print E2E_PASSWORD, nothing else
# on stdout. Sourcing this file never does this — it only defines the functions
# above, so a sourcing caller controls exactly when generation happens.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  e2e_password_ensure
  printf '%s\n' "${E2E_PASSWORD}"
fi

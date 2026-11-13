#!/usr/bin/env bash
# gen-stack-db-env.sh — make sure tests/stack/.env holds one password per local-stack
# role (the keys in tests/stack/stack-db-passwords.tsv). Create, never rotate.
#
# WHY IT EXISTS (hugmesh-generator#857). Until 2026-11-04 the tests/stack/compose*.yaml
# files spelled every Postgres password inline, and 26 of the 28 values equalled the
# role's own name (federation/federation, adminbff/adminbff, casdoor/casdoor, ...).
# A volume initialised with one of those keeps it, and a stack exposed on a LAN door
# (`make lan-*`) served databases whose passwords were their role names. The compose
# files now read ${KEY:?...} and spell no value at all; this script supplies them.
# It is the multi-key sibling of tests/stack/gen-route-access-env.sh (#838), which
# still owns ROUTE_ACCESS_DB_PASSWORD alone; read that header for the background.
#
# WHY tests/stack/.env. compose loads it BY ITSELF for any `-f tests/stack/compose*.yaml`
# (including the files compose.local.yaml `include:`s), from any working directory, so
# a hand-run compose and the Studio's `up --scale` get the values too. An `--env-file X`
# disables that auto-load (the Makefile's m2 registry adds one), so the Makefile ALSO
# passes every key explicitly (STACK_DB_ENV, via --read below).
#
# FAIL LOUD. compose interpolates the WHOLE file before it applies profiles, so a
# missing key stops EVERY compose command on these files (up, config, ps, down) with
# "required variable KEY is missing a value: run tests/stack/gen-stack-db-env.sh".
# No container is ever created with an empty or default password. The read-only
# paths (make stack-ps/logs/onion, the Studio's status/log reads) pass a placeholder
# for a key that is not set yet instead of running this script: looking never mints.
#
# THE FILE IS SHARED, SO THIS SCRIPT OWNS ITS KEYS, NOT THE FILE. Every write keeps
# every other line (the operator's overrides, gen-route-access-env.sh's block) and
# only replaces this script's marked block and any line setting one of its keys. The
# file is 0600 and gitignored. A SYMLINKED .env stays a symlink (its target is
# replaced atomically in the target's own directory; --remove never deletes it).
#
# CREATE, NEVER ROTATE. The postgres image honours POSTGRES_PASSWORD only when it
# initialises an EMPTY data dir, and the service-account password is baked into the
# accounts the brokers registered. A non-empty value already in the file is ALWAYS
# kept. `make stack-down` / `make stack-clean` drop the volumes and then run --remove,
# so the next stack-up mints fresh values for fresh volumes.
#
# WHEN A KEY IS MISSING, where its value comes from (first match wins):
#   1. one of the key's volumes (<project>_<volume>) EXISTS — the operator's running
#      or halted stack. A random value would lock it out, so the volume's value is
#      ADOPTED, and stderr says so:
#      a. from the project's <service> container, running or stopped: the <ctr_env>
#         it was created with is what the volume was initialised with;
#      b. otherwise the table's legacy literal: every volume created before
#         2026-11-04 was initialised with it (an operator who exported their own
#         SVC_PASSWORD then must put it in .env by hand).
#      The adopted value equals the role name. Rotating it is a one-shot, see
#      ROTATING below; doing nothing keeps today's behaviour exactly.
#   2. docker cannot answer (daemon down, wrong context): nothing is written and the
#      run fails, rather than guess.
#   3. no volume: a fresh random value (48 hex).
#
# ROTATING AN ADOPTED VALUE without dropping data (prints nothing secret; run it
# yourself, against YOUR stack, while it is up):
#     bash tests/stack/gen-stack-db-env.sh --rotate-sql KEY
# prints the steps for KEY: ALTER ROLE inside the DB container (the new value goes
# through psql's stdin and is never printed), then the .env line, then `make
# stack-up` so every consumer is recreated with it.
# The simple path is `make stack-down` (DROPS the data) and `make stack-up`.
#
# MULTIPLE PROJECTS / CHECKOUTS. compose.local.yaml says `name: hugmesh-local`, while
# tests/stack/up-real.sh runs compose.real.yaml as `hugmesh-real`; both read the SAME
# tests/stack/.env. Adoption probes one project (STACK_DB_PROJECT, else
# COMPOSE_PROJECT_NAME, else hugmesh-local); up-real.sh passes hugmesh-real. A key
# that is already in the file is never re-probed, so if the two projects' volumes
# were initialised differently, copy the right value into the file by hand. A second
# checkout of the repo adopts from the first one's containers while they exist.
#
# VERIFY (2026-11-12). A key already in the file is never re-probed, and every
# checkout has its own .env while the project, and so the volumes, is shared. A
# second tree that created phpbb-pg/akkoma-pg/casdoor-brandb-pg locked the operator's
# checkout out of them, and the first symptom was a service crash-looping on auth.
# --verify checks each key against the project's existing data BEFORE compose runs:
#   a. its Postgres container is RUNNING: the value is tried over TCP inside it
#      (`psql -h 127.0.0.1`, which the postgres image password-checks; the value
#      goes through stdin, never argv). That is the volume's real credential, so a
#      rotation done with --rotate-sql passes;
#   b. a STOPPED container: the value it was created with must equal the file's;
#   c. no container, but a volume: a value this script GENERATED more than a minute
#      after the volume was created cannot be what initialised it.
# A mismatch names the key, the container or volume and the tree that created it
# (compose labels), never a value, and points at --rotate-sql or the owning tree.
#
# URL- AND CONNSTRING-SAFE BY CONSTRUCTION. Casdoor reads its password inside a libpq
# connection string (`password=... host=...`) and the BFFs inside r2dbc/JDBC configs,
# so a value outside [A-Za-z0-9._~-] (hand-edited, or adopted) is refused.
#
# Usage: gen-stack-db-env.sh               ensure every key exists (quiet when they do)
#        gen-stack-db-env.sh --read KEY    READ ONLY: print KEY's value if the file holds
#                                          one, else nothing; never probes docker, never
#                                          writes (the Makefile's STACK_DB_ENV)
#        gen-stack-db-env.sh --keys        print the key names, one per line
#        gen-stack-db-env.sh --remove      strip this script's block and keys from the
#                                          file; delete the file if nothing else is left
#        gen-stack-db-env.sh --rotate-sql KEY   print the rotation steps for KEY
#        gen-stack-db-env.sh --verify      READ ONLY: refuse (exit 4) when a value in the
#                                          file is NOT what the project's existing data
#                                          holds (see VERIFY above); make stack-up runs it
# Env:   STACK_DB_ENV_FILE  the file (default tests/stack/.env)
#        STACK_DB_TABLE     the key table (default tests/stack/stack-db-passwords.tsv)
#        STACK_DB_PROJECT   compose project (default ${COMPOSE_PROJECT_NAME:-hugmesh-local})
#        DOCKER             the docker CLI (default docker)
# Guard: tests/stack/test-gen-stack-db-env.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${STACK_DB_ENV_FILE:-${HERE}/.env}"
TABLE="${STACK_DB_TABLE:-${HERE}/stack-db-passwords.tsv}"
PROJECT="${STACK_DB_PROJECT:-${COMPOSE_PROJECT_NAME:-hugmesh-local}}"
DOCKER="${DOCKER:-docker}"
BEGIN_MARK="# >>> local stack DB passwords (tests/stack/gen-stack-db-env.sh) >>>"
END_MARK="# <<< local stack DB passwords <<<"
ME=gen-stack-db-env.sh

[ -f "${TABLE}" ] || { echo "${ME}: key table ${TABLE} is missing" >&2; exit 2; }

# The table, parsed once: parallel arrays indexed by row.
K_KEY=(); K_SVC=(); K_CENV=(); K_VOLS=(); K_LEGACY=()
while IFS=$'\t' read -r k s c v l || [ -n "${k}" ]; do
  case "${k}" in ""|\#*) continue ;; esac
  if [ -z "${s}" ] || [ -z "${c}" ] || [ -z "${v}" ] || [ -z "${l}" ]; then
    echo "${ME}: malformed row for '${k}' in ${TABLE} (want 5 TAB-separated columns)" >&2
    exit 2
  fi
  K_KEY+=("${k}"); K_SVC+=("${s}"); K_CENV+=("${c}"); K_VOLS+=("${v}"); K_LEGACY+=("${l}")
done < "${TABLE}"
[ "${#K_KEY[@]}" -gt 0 ] || { echo "${ME}: no keys in ${TABLE}" >&2; exit 2; }
KEY_ALT="$(IFS='|'; echo "${K_KEY[*]}")"

# A symlinked env file: every write goes to the link's TARGET, so the link survives.
ENV_IS_LINK=0
if [ -L "${ENV_FILE}" ]; then
  ENV_IS_LINK=1
  target="$(readlink -f -- "${ENV_FILE}" 2>/dev/null)" || target=""
  if [ -z "${target}" ] || [ ! -d "$(dirname -- "${target}")" ]; then
    echo "${ME}: ${ENV_FILE} is a symlink whose target directory does not exist;" >&2
    echo "  fix or remove the link and retry. Nothing was written." >&2
    exit 1
  fi
  ENV_FILE="${target}"
fi

mode=ensure
arg=""
case "${1:-}" in
  --read|--rotate-sql)
    mode="${1#--}"
    arg="${2:-}"
    [ -n "${arg}" ] || { echo "${ME}: $1 needs a KEY" >&2; exit 2; } ;;
  --keys) mode=keys ;;
  --verify) mode=verify ;;
  --remove) mode=remove ;;
  "") ;;
  *) echo "${ME}: unknown argument: $1" >&2; exit 2 ;;
esac

idx_of() { # idx_of KEY -> the row index, or exit 2
  local i
  for i in "${!K_KEY[@]}"; do
    [ "${K_KEY[$i]}" = "$1" ] && { echo "${i}"; return 0; }
  done
  echo "${ME}: unknown key '$1' (see ${TABLE##*/})" >&2
  return 2
}

# read_key <file> <KEY> -> the LAST value compose would read for KEY (dotenv: optional
# `export `, spaces around `=`, one pair of matching quotes), or nothing.
read_key() {
  [ -f "$1" ] || return 0
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$2[[:space:]]*=[[:space:]]*//p" "$1" \
    | tail -1 | sed -E -e 's/[[:space:]]+$//' -e "s/^\"(.*)\"\$/\\1/" -e "s/^'(.*)'\$/\\1/"
}

# origin_of <file> <KEY> -> the `# KEY: <origin>` note this script wrote, or nothing.
origin_of() {
  [ -f "$1" ] || return 0
  sed -n "s/^# $2: //p" "$1" | tail -1
}

# without_keys <file> -> the file's lines minus this script's block and any key line.
without_keys() {
  [ -f "$1" ] || return 0
  awk -v b="${BEGIN_MARK}" -v e="${END_MARK}" -v k="${KEY_ALT}" '
    $0 == b { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    skip { next }
    $0 ~ "^[[:space:]]*(export[[:space:]]+)?(" k ")[[:space:]]*=" { next }
    { print }' "$1"
}

safe() { case "$1" in ""|*[!A-Za-z0-9._~-]*) return 1 ;; esac; }

replace_file() { # replace_file <content-file>: atomic, 0600, in the target's directory
  local tmp
  tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
  ( umask 077; cat "$1" > "${tmp}" ) || { rm -f "${tmp}"; return 1; }
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${ENV_FILE}"
}

if [ "${mode}" = keys ]; then
  printf '%s\n' "${K_KEY[@]}"
  exit 0
fi

if [ "${mode}" = read ]; then
  idx_of "${arg}" >/dev/null || exit 2
  val="$(read_key "${ENV_FILE}" "${arg}")"
  [ -n "${val}" ] || exit 0
  if ! safe "${val}"; then
    echo "${ME}: ${arg} in ${ENV_FILE} holds a character outside [A-Za-z0-9._~-]; fix the file." >&2
    exit 1
  fi
  printf '%s' "${val}"
  exit 0
fi

if [ "${mode}" = rotate-sql ]; then
  i="$(idx_of "${arg}")" || exit 2
  svc="${K_SVC[$i]}"
  if [ "${K_CENV[$i]}" != POSTGRES_PASSWORD ]; then
    cat <<EOF
${arg} is not a Postgres role password: it is baked into every account the brokers
registered on tuwunel and Mastodon. Rotating it in place means re-keying those
accounts; the supported path is \`make stack-down\` (DROPS the data) then \`make stack-up\`.
EOF
    exit 0
  fi
  cat <<EOF
Rotate ${arg} in place, keeping the data. Run these yourself, against YOUR stack,
while its ${svc} container is up; nothing below prints the value, and psql reads
it from stdin.
  cid="\$(docker ps -q --filter label=com.docker.compose.project=${PROJECT} \\
           --filter label=com.docker.compose.service=${svc})"
  new="\$(openssl rand -hex 24)"
  printf "ALTER ROLE CURRENT_USER PASSWORD '%s';\\n" "\$new" | docker exec -i "\$cid" \\
    sh -c 'exec psql -X -q -v ON_ERROR_STOP=1 -U "\$POSTGRES_USER" -d "\$POSTGRES_DB"' \\
  && sed -i "s/^${arg}=.*/${arg}=\$new/" tests/stack/.env; unset new
  make stack-up      # recreates ${svc}'s consumers with the new value
psql inside the container uses the local socket, which the postgres image trusts,
so no old password is needed; the .env line changes only if ALTER ROLE succeeded.
EOF
  exit 0
fi

if [ "${mode}" = remove ]; then
  [ -f "${ENV_FILE}" ] || exit 0
  rest="$(mktemp)"; trap 'rm -f "${rest}"' EXIT
  without_keys "${ENV_FILE}" > "${rest}"
  if grep '[^[:space:]]' "${rest}" >/dev/null; then
    replace_file "${rest}"
    echo "==> Removed the local stack DB passwords from ${ENV_FILE} (other lines kept)"
  elif [ "${ENV_IS_LINK}" -eq 1 ]; then
    replace_file "${rest}"
    echo "==> Removed the local stack DB passwords from ${ENV_FILE} (symlinked; the file is kept, now empty)"
  else
    rm -f "${ENV_FILE}"
    echo "==> Removed ${ENV_FILE} (it held only the local stack DB passwords)"
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

# probe_volume <name> -> 0 exists, 1 does not, 2 docker could not say.
probe_volume() {
  command -v "${DOCKER}" >/dev/null 2>&1 || return 1  # no docker CLI: no volume here
  local err
  if err="$("${DOCKER}" volume inspect "$1" 2>&1 >/dev/null)"; then return 0; fi
  case "$(printf '%s' "${err}" | tr '[:upper:]' '[:lower:]')" in
    *"no such volume"*) return 1 ;;
  esac
  return 2
}

# container_value <service> <env-var> -> sets FROM_CTR (or '') and CTR_EXISTS.
# Called directly, not in $(...), so both globals survive.
FROM_CTR=""
CTR_EXISTS=0
container_value() {
  local cid
  FROM_CTR=""; CTR_EXISTS=0
  cid="$("${DOCKER}" ps -a -q \
    --filter "label=com.docker.compose.project=${PROJECT}" \
    --filter "label=com.docker.compose.service=$1" 2>/dev/null)" || return 0
  cid="${cid%%$'\n'*}"
  [ -n "${cid}" ] || return 0
  CTR_EXISTS=1
  FROM_CTR="$("${DOCKER}" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${cid}" 2>/dev/null \
    | sed -n "s/^$2=//p" | tail -1)" || FROM_CTR=""
}

# to_epoch <docker/ISO time> -> seconds since the epoch, or nothing.
to_epoch() { date -u -d "$1" +%s 2>/dev/null || true; }

# pg_auth_ok <container> <password> -> 0 the password signs in over TCP, 1 it is
# refused, 2 the probe could not tell (no psql, not ready, ...).
pg_auth_ok() {
  local out
  out="$(printf '%s\n' "$2" | "${DOCKER}" exec -i "$1" sh -c \
    'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql -X -q -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select 1"' 2>&1)"
  case "${out}" in
    1) return 0 ;;
    *"password authentication failed"*) return 1 ;;
  esac
  return 2
}

if [ "${mode}" = verify ]; then
  [ -f "${ENV_FILE}" ] || exit 0
  command -v "${DOCKER}" >/dev/null 2>&1 || exit 0
  bad=0
  for i in "${!K_KEY[@]}"; do
    key="${K_KEY[$i]}"; svc="${K_SVC[$i]}"
    val="$(read_key "${ENV_FILE}" "${key}")"
    [ -n "${val}" ] || continue
    cid="$("${DOCKER}" ps -a -q --filter "label=com.docker.compose.project=${PROJECT}" \
            --filter "label=com.docker.compose.service=${svc}" 2>/dev/null)" || cid=""
    cid="${cid%%$'\n'*}"
    why=""
    if [ -n "${cid}" ]; then
      running="$("${DOCKER}" inspect -f '{{.State.Running}}' "${cid}" 2>/dev/null || echo false)"
      if [ "${running}" = true ] && [ "${K_CENV[$i]}" = POSTGRES_PASSWORD ]; then
        pg_auth_ok "${cid}" "${val}" && rc=0 || rc=$?
        [ "${rc}" -ne 1 ] || why="the running ${svc} container's database refuses it"
      else
        container_value "${svc}" "${K_CENV[$i]}"
        if [ -n "${FROM_CTR}" ] && [ "${FROM_CTR}" != "${val}" ]; then
          why="the existing ${svc} container was created with a different value"
        fi
      fi
      if [ -n "${why}" ]; then
        wd="$("${DOCKER}" inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "${cid}" 2>/dev/null || true)"
        [ -z "${wd}" ] || why="${why} (that container was created from ${wd%/tests/stack})"
      fi
    else
      gen="$(origin_of "${ENV_FILE}" "${key}")"
      case "${gen}" in
        "generated "*)
          g="$(to_epoch "${gen#generated }")"
          for vol in ${K_VOLS[$i]}; do
            c="$("${DOCKER}" volume inspect -f '{{.CreatedAt}}' "${PROJECT}_${vol}" 2>/dev/null)" || continue
            c="$(to_epoch "${c}")"
            if [ -n "${g}" ] && [ -n "${c}" ] && [ "${c}" -lt $((g - 60)) ]; then
              why="volume ${PROJECT}_${vol} was created before this value was generated, so it holds another one"
              break
            fi
          done ;;
      esac
    fi
    if [ -n "${why}" ]; then
      bad=$((bad + 1))
      echo "${ME}: ${key} in ${ENV_FILE} does not match project ${PROJECT}'s data: ${why}." >&2
    fi
  done
  if [ "${bad}" -gt 0 ]; then
    cat >&2 <<EOF
${ME}: REFUSED: ${bad} key(s) above would make their service fail to sign in to its own
  database (a crash loop on "password authentication failed"). The data was created
  by another tree, or the file lost the value it was created with. Do one of:
    * drive the stack from the tree that created it (make stack-owner-check names it);
    * copy that tree's value for each key into ${ENV_FILE};
    * keep this file's value and re-key the database while it runs:
        bash tests/stack/${ME} --rotate-sql <KEY>   (prints the steps, keeps the data)
    * or drop just that service's data: make stack-reset-volume SVC=<service>.
  No value is printed. Nothing was changed.
EOF
    exit 4
  fi
  exit 0
fi

# Resolve every key first; write once at the end (or not at all).
VALS=(); ORIGINS=(); missing=0
for i in "${!K_KEY[@]}"; do
  key="${K_KEY[$i]}"
  val="$(read_key "${ENV_FILE}" "${key}")"
  if [ -n "${val}" ]; then
    if ! safe "${val}"; then
      echo "${ME}: ${key} in ${ENV_FILE} holds a character outside [A-Za-z0-9._~-];" >&2
      echo "  a connection string would read it differently. Fix the file." >&2
      exit 1
    fi
    VALS[$i]="${val}"
    ORIGINS[$i]="$(origin_of "${ENV_FILE}" "${key}")"
    [ -n "${ORIGINS[$i]}" ] || ORIGINS[$i]="kept (set outside this script)"
    continue
  fi
  missing=$((missing + 1))
  found=""
  for vol in ${K_VOLS[$i]}; do
    probe_volume "${PROJECT}_${vol}" && pv=0 || pv=$?
    if [ "${pv}" -eq 2 ]; then
      echo "${ME}: docker could not say whether volume ${PROJECT}_${vol} exists," >&2
      echo "  so NOTHING was written to ${ENV_FILE} (a new ${key} would lock an existing" >&2
      echo "  volume out). Start docker, or check DOCKER_HOST / the docker context, and retry." >&2
      exit 1
    fi
    if [ "${pv}" -eq 0 ]; then found="${PROJECT}_${vol}"; break; fi
  done
  if [ -n "${found}" ]; then
    container_value "${K_SVC[$i]}" "${K_CENV[$i]}"
    if [ -n "${FROM_CTR}" ]; then
      val="${FROM_CTR}"
      ORIGINS[$i]="adopted from the existing ${PROJECT} ${K_SVC[$i]} container (volume ${found} predates this key)"
      echo "WARNING: ${key} adopted from the existing ${K_SVC[$i]} container (volume ${found} exists)." >&2
      echo "         The stack keeps working as before." >&2
    else
      val="${K_LEGACY[$i]}"
      ORIGINS[$i]="adopted: volume ${found} predates this key and no ${K_SVC[$i]} container is left (assumed the pre-2026-11-04 compose literal)"
      if [ "${CTR_EXISTS}" -eq 1 ]; then
        why="its ${K_SVC[$i]} container carries no ${K_CENV[$i]}"
      else
        why="no ${K_SVC[$i]} container is left to read it from"
      fi
      echo "WARNING: ${key}: volume ${found} exists and ${why};" >&2
      echo "         assumed the compose literal used before 2026-11-04. That is right only" >&2
      echo "         for a volume created before that date. A volume created later was" >&2
      echo "         given a generated value: if ${ENV_FILE##*/} lost it (or this is a second" >&2
      echo "         checkout), put that value back in the file instead, or every service" >&2
      echo "         using ${key} will fail to sign in." >&2
    fi
    echo "         To rotate it: bash tests/stack/${ME} --rotate-sql ${key}" >&2
  else
    val="$(mint)"
    ORIGINS[$i]="generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  if ! safe "${val}"; then
    echo "${ME}: the value resolved for ${key} is empty or outside [A-Za-z0-9._~-]. Nothing was written." >&2
    exit 1
  fi
  VALS[$i]="${val}"
done

if [ "${missing}" -gt 0 ]; then
  merged="$(mktemp)"; trap 'rm -f "${merged}"' EXIT
  { without_keys "${ENV_FILE}"
    echo "${BEGIN_MARK}"
    echo "# GENERATED, gitignored, never commit. Each value must match what its volume was"
    echo "# initialised with: do not edit or delete one while that volume exists (make"
    echo "# stack-down removes both). Other lines in this file are yours and are kept."
    for i in "${!K_KEY[@]}"; do
      echo "# ${K_KEY[$i]}: ${ORIGINS[$i]}"
      printf '%s=%s\n' "${K_KEY[$i]}" "${VALS[$i]}"
    done
    echo "${END_MARK}"
  } > "${merged}"
  replace_file "${merged}"
  echo "==> Wrote ${missing} local stack DB password(s) to ${ENV_FILE}"
fi
# Keep a credential-bearing file private even when the operator created it wider.
chmod 600 "${ENV_FILE}" 2>/dev/null || true

#!/usr/bin/env bash
# test-route-access-reconcile.sh — the guard over the local stack's route-access
# reconcile (tests/stack/route-access-reconcile.sh, wired into `make stack-up`).
#
# THE DEFECT IT PINS (measured 2026-10-29): compose.local.yaml seeds
# gateway_route_access only via /docker-entrypoint-initdb.d, i.e. on the volume's
# FIRST init. After #824 merged, `make stack-up GAMES=1` on an existing stack left
# 1 of the 8 fe /games rows in the live table and every games member got 403; the
# gateways replace their baked seed with the DB rows on a 5 s refresh, so the
# stale table was authoritative until the file was re-applied by hand.
#
# TWO LEGS:
#   1. STATIC WIRING (always runs; make + bash + coreutils only, no docker):
#      `make -n stack-up` (make's REAL recipe expansion, nothing executed; the
#      prerequisites are marked old with -o so no clone/cert/m2 step is even
#      printed) must show the reconcile invocation AFTER the `compose … up -d`
#      line; `make -n stack-route-access-reconcile` must exist; scripts/stack-up.ps1
#      (the Windows bring-up, which never goes through make) must carry the same
#      step after its `up -d`, with no `"` inside any of its `docker … sh -c`
#      arguments (Windows PowerShell 5.1 splits `-c "SELECT 1"`), its readiness probe
#      under ErrorActionPreference Continue (restored before the apply), and its -f
#      path equal to compose.local.yaml's mount target; and the reconciler's apply line must carry BOTH
#      `-v ON_ERROR_STOP=1` and `-1`. Every assertion is mutation-tested on a
#      staged copy (line removed / moved before `up -d` / `-` ignore-error prefix /
#      flag stripped) and must go RED, with the mutation's landing proven by diff.
#   2. ENGINE (postgres:16-alpine, the exact image the stack runs): starts from a
#      table the image's own initdb seeded from the real file, then proves
#        * a seed row the table LACKS comes back on the next reconcile (the 8 fe
#          /games rows — the incident shape), and an admin-ADDED row survives;
#        * an admin's edits to an EXISTING row are preserved: allow=false on a
#          seed row, and mfa_required=true OUTSIDE the file's blanket prefixes;
#        * the file's documented convergence still holds through the reconciler:
#          mfa_required=false under /bff/admin (unscoped or domain-scoped) is
#          re-flipped true — the "OPERATOR CAVEAT" contract, not a clobber;
#        * re-running is a no-op (inserted 0, rewritten 0, fingerprint identical);
#        * a SQL error leaves the table UNTOUCHED and exits non-zero (-1 +
#          ON_ERROR_STOP together), and each flag's removal from a staged copy of
#          the reconciler turns exactly that assertion red.
#      Engine selection: POSTGRES_HOST set -> that server (CI `services:`,
#      FAIL-CLOSED: unreachable or no psql is a failure); else a docker daemon ->
#      a throwaway container with a unique name, removed on exit; else NOT RUN
#      (printed), unless ROUTE_ACCESS_RECONCILE_REQUIRE_ENGINE=1 makes that a
#      failure. The reconciler is ONLY ever invoked with ROUTE_ACCESS_CONTAINER or
#      POSTGRES_HOST set, and STACK_COMPOSE is pointed at a non-file, so a
#      fall-through to the default compose target (an operator's running stack)
#      fails fast instead of touching it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${REPO}/tests/stack/route-access-reconcile.sh"
SQL="${REPO}/specs/cluster/manifests/route-access/initdb/20-schema.sql"
PS1_SCRIPT="${REPO}/scripts/stack-up.ps1"

# NEVER the operator's stack: no fall-through to the compose target can resolve.
export STACK_COMPOSE="/nonexistent/this-guard-never-targets-a-running-stack.yaml"
export COMPOSE_CMD="false"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/ra-reconcile-guard.XXXXXX")"
CONTAINER=""
cleanup() {
  if [ -n "${CONTAINER}" ]; then docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true; fi
  rm -rf "${W}"
}
trap cleanup EXIT

for t in make bash awk sed diff python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "  FAIL toolchain missing: $t"; exit 2; }
done
[ -f "${SCRIPT}" ] || { bad "reconciler missing: ${SCRIPT}"; echo "passed=${P} failed=${F}"; exit 1; }
[ -f "${SQL}" ]    || { bad "seed missing: ${SQL}"; echo "passed=${P} failed=${F}"; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════
echo "── 1) STATIC WIRING ──"
# ═══════════════════════════════════════════════════════════════════════════

# dry_run <Makefile> <target>: make's expansion of the recipe, nothing executed.
# -o marks every stack-up prerequisite old so their recipes are neither run nor
# printed (stack-m2-check's recipe contains $(MAKE), which `make -n` WOULD run).
dry_run() {
  (cd "${REPO}" && timeout 60 make -n -f "$1" -o stack-clone -o stack-certs -o stack-m2-check -o stack-mastodon-env "$2" 2>/dev/null)
}
# positions <dry-run output>: "up=<line> rec=<line>" — the compose `up -d` command
# line and the FIRST reconciler invocation (0 = absent). Comment lines are skipped
# so a recipe comment that merely MENTIONS `up -d` cannot satisfy the check.
positions() {
  awk '
    /^[[:space:]]*#/ { next }
    / up -d$/ && !up { up = NR }
    /route-access-reconcile\.sh/ && !rec { rec = NR }
    END { printf "up=%d rec=%d\n", up+0, rec+0 }'
}
# check_make <Makefile> -> 0 when stack-up invokes the reconciler AFTER `up -d`
# and the invocation is not `-`-prefixed (make's ignore-error, which would turn
# "fail loud" into a printed error and a green stack-up).
check_make() {
  local mk="$1"
  local out pos up rec
  out="$(dry_run "${mk}" stack-up)" || return 1
  pos="$(printf '%s\n' "${out}" | positions)"
  up="${pos#up=}"; up="${up%% *}"; rec="${pos##*rec=}"
  [ "${up}" -gt 0 ] && [ "${rec}" -gt 0 ] && [ "${rec}" -gt "${up}" ] || return 1
  # the recipe line in the SOURCE must not start with `-` (ignore-error)
  if awk '/^stack-up:/{s=1; next} s && /^[^\t]/{s=0} s && /route-access-reconcile\.sh/ && /^\t-/ {bad=1} END{exit bad?1:0}' "${mk}"; then :; else return 1; fi
  return 0
}

REAL_POS="$(dry_run "${REPO}/Makefile" stack-up | positions)"
if check_make "${REPO}/Makefile"; then
  ok "make -n stack-up invokes tests/stack/route-access-reconcile.sh AFTER the compose \`up -d\` line (${REAL_POS})"
else
  bad "make -n stack-up does not invoke the reconciler after \`up -d\` (${REAL_POS}) — an existing stack keeps its stale route table"
fi

if dry_run "${REPO}/Makefile" stack-route-access-reconcile | grep 'route-access-reconcile\.sh' >/dev/null; then
  ok "make stack-route-access-reconcile exists and invokes the reconciler (a stack that is already up can converge without a bring-up)"
else
  bad "make stack-route-access-reconcile is missing or does not invoke tests/stack/route-access-reconcile.sh"
fi

# make -p's database says "Phony target" under a target that .PHONY names.
if (cd "${REPO}" && timeout 60 make -pn -o stack-clone -o stack-certs -o stack-m2-check -o stack-mastodon-env stack-route-access-reconcile 2>/dev/null) \
     | awk '/^stack-route-access-reconcile:/{f=1; next} f && /Phony target/{found=1} f && /^$/{f=0} END{exit found?0:1}'; then
  ok "stack-route-access-reconcile is listed in .PHONY"
else
  bad "stack-route-access-reconcile is not in .PHONY — a file of that name would silence the target"
fi

# check_pin <Makefile> <target>: the target's reconcile invocation blanks
# POSTGRES_HOST and ROUTE_ACCESS_CONTAINER. The reconciler honours both as target
# overrides (this guard and CI use them), and make passes the operator's shell
# environment through: a POSTGRES_HOST exported for a seed replay
# (docs/MFA-ROLLOUT.md) would send stack-up's seed to THAT server and leave the
# stack's own table stale — the incident this target exists to close.
check_pin() {
  local line
  line="$(dry_run "$1" "$2" | grep 'route-access-reconcile\.sh' | head -n 1)"
  [ -n "${line}" ] || return 1
  printf '%s\n' "${line}" | grep -E '(^| )POSTGRES_HOST= ' >/dev/null || return 1
  printf '%s\n' "${line}" | grep -E '(^| )ROUTE_ACCESS_CONTAINER= ' >/dev/null || return 1
}
for t in stack-up stack-route-access-reconcile; do
  if check_pin "${REPO}/Makefile" "${t}"; then
    ok "make ${t} blanks POSTGRES_HOST and ROUTE_ACCESS_CONTAINER on the reconcile line (a shell export cannot redirect it off the compose stack)"
  else
    bad "make ${t}'s reconcile line does not blank POSTGRES_HOST= ROUTE_ACCESS_CONTAINER= — an exported POSTGRES_HOST redirects the seed to another server"
  fi
done

# The reconciler's apply line: ONE transaction + stop on first error.
APPLY_LINE="$(grep -n '<"\${SQL}"' "${SCRIPT}" | head -n 1)"
if [ -n "${APPLY_LINE}" ] && printf '%s' "${APPLY_LINE}" | grep -- '-v ON_ERROR_STOP=1' >/dev/null && printf '%s' "${APPLY_LINE}" | grep -E -- ' -1 ' >/dev/null; then
  ok "the reconciler applies the seed with -v ON_ERROR_STOP=1 AND -1 (one transaction; a failure rolls everything back and exits non-zero)"
else
  bad "the reconciler's apply line lacks ON_ERROR_STOP and/or -1: $(printf '%s' "${APPLY_LINE:-<no apply line found>}" | cut -c1-120)"
fi

# Windows bring-up (scripts/stack-up.ps1) never goes through make. The file is
# `eol=crlf` in .gitattributes, so a fresh checkout carries \r before every
# newline: the end-of-line anchor must tolerate it or the check is red on every
# clone and green only on a tree something rewrote with LF.
ps1_ok() {
  awk '
    /^[[:space:]]*#/ { next }
    /^docker compose .* up -d\r?$/ && !up { up = NR }
    /psql .*ON_ERROR_STOP=1 -1 / && !rec { rec = NR }
    END { exit (up > 0 && rec > up) ? 0 : 1 }' "$1"
}
if ps1_ok "${PS1_SCRIPT}"; then
  ok "scripts/stack-up.ps1 re-applies the seed (psql … ON_ERROR_STOP=1 -1) after its \`up -d\`"
else
  bad "scripts/stack-up.ps1 does not re-apply the seed after \`up -d\` — the Windows bring-up keeps a stale route table"
fi

# Windows PowerShell 5.1 (the file's `#requires -Version 5.1`) and pwsh 7.0-7.2 use
# "Legacy" native argument passing: an embedded `"` inside an argument is NOT
# escaped on docker's command line, so `sh -c '… -c "SELECT 1"'` reaches sh as
# `-c SELECT` plus a stray `1` — the readiness loop can never succeed and the
# count queries break. Measured 2026-10-29 with pwsh 7.1.5 (Legacy) and a stub
# docker printing its argv. So: no `"` in any `docker … sh -c` line of the step.
ps1_quotes_ok() {
  awk '
    /^# ── 3b\./ { s = 1; next }
    s && /route-access reconcile: \$before/ { s = 0 }
    s && /^[[:space:]]*#/ { next }
    s && /docker compose .* sh -c / && /"/ { bad = 1 }
    s && /docker compose .* sh -c / { n++ }
    END { exit (n >= 4 && !bad) ? 0 : 1 }' "$1"
}
if ps1_quotes_ok "${PS1_SCRIPT}"; then
  ok "scripts/stack-up.ps1's reconcile step passes no embedded \" to docker (Windows PowerShell 5.1 would split \`-c \"SELECT 1\"\`)"
else
  bad "scripts/stack-up.ps1's reconcile step has a \" inside a docker \`sh -c\` argument (or fewer than 4 such calls) — Windows PowerShell 5.1 mangles it"
fi

# The readiness probe is EXPECTED to fail while the DB starts, and it redirects
# the native command (`*> $null`). Under the script's $ErrorActionPreference =
# 'Stop', Windows PowerShell 5.1 and pwsh 7.0/7.1 turn that redirected stderr into
# a terminating error: the first not-ready probe ended the script instead of
# retrying (reproduced 2026-10-29 with pwsh 7.1.5 and a stub docker that fails
# twice). So the probe must sit after a `$ErrorActionPreference = 'Continue'` and
# the preference must be restored before the apply line.
ps1_eap_ok() {
  awk '
    /^# ── 3b\./ { s = 1; next }
    s && /route-access reconcile: \$before/ { s = 0 }
    s && /^[[:space:]]*#/ { next }
    s && /^[[:space:]]*\$ErrorActionPreference = .Continue./ && !cont { cont = NR }
    s && /\*> \$null/ && !probe { probe = NR }
    s && probe && /^[[:space:]]*\$ErrorActionPreference = \$/ && !restore { restore = NR }
    s && /ON_ERROR_STOP=1 -1 / && !apply { apply = NR }
    END { exit (cont && probe && restore && apply && cont < probe && probe < restore && restore < apply) ? 0 : 1 }' "$1"
}
if ps1_eap_ok "${PS1_SCRIPT}"; then
  ok "scripts/stack-up.ps1 runs its readiness probe under ErrorActionPreference 'Continue' and restores the preference before the apply (a not-ready probe retries instead of ending the script)"
else
  bad "scripts/stack-up.ps1's readiness probe is not wrapped in ErrorActionPreference 'Continue' + restore — under 'Stop' the first not-ready probe ends the script on PowerShell 5.1"
fi

# The ps1 must apply the CHECKOUT's seed, not the container's bind mount. A
# single-file bind mount pins the inode it had at container start; `git pull`
# replaces 20-schema.sql with a new file, so a container that kept running would
# re-apply the OLD seed and report success (ultrareview finding, 2026-10-29). So:
# the ps1 copies the host seed in (`compose cp`) and the apply's -f names exactly
# the copy's in-container path — never a /docker-entrypoint-initdb.d name.
ps1_path_ok() {  # ps1_path_ok <ps1>
  local dest
  dest="$(grep -v '^[[:space:]]*#' "$1" | grep -E "route-access[\\/]initdb[\\/]20-schema\.sql" >/dev/null && \
          grep -v '^[[:space:]]*#' "$1" | sed -n 's#^docker compose .* cp \$SeedSql route-access-db:\([^[:space:]]*\).*#\1#p' | head -n 1)"
  [ -n "${dest}" ] || return 1
  grep -v '^[[:space:]]*#' "$1" | grep -E -- "ON_ERROR_STOP=1 -1 -f ${dest//./\\.}'" >/dev/null || return 1
  ! grep -v '^[[:space:]]*#' "$1" | grep -E -- 'ON_ERROR_STOP=1 -1 -f /docker-entrypoint-initdb\.d/' >/dev/null
}
if ps1_path_ok "${PS1_SCRIPT}"; then
  ok "scripts/stack-up.ps1 copies the checkout's 20-schema.sql into route-access-db and applies that copy (a git pull under a running container cannot leave it re-applying the old seed)"
else
  bad "scripts/stack-up.ps1 does not apply a fresh copy of the checkout's seed (it reads the bind mount, whose inode a git pull leaves stale)"
fi

# ── Static MUTATIONS on staged copies: each must go RED, and each is proven to
#    have landed (diff non-empty) before its verdict counts.
mutate_make() {  # mutate_make <name> <python-transform>
  # bash 5.3 localises every name BEFORE assigning, so `local a=$1 b=$a` dies
  # under set -u: one name per statement.
  local name="$1"
  local py="$2"
  local dst="${W}/Makefile.${name}"
  python3 - "${REPO}/Makefile" "${dst}" "${py}" <<'PY'
import sys, re
src, dst, how = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
m = re.search(r'^stack-up:.*?\n(?P<body>(?:\t.*\n)+)', s, re.M)
body = m.group('body')
lines = body.split('\n')
rec = next(i for i, l in enumerate(lines) if 'route-access-reconcile.sh' in l)
up = next(i for i, l in enumerate(lines) if l.rstrip().endswith('up -d'))
if how == 'remove':
    del lines[rec]
elif how == 'before':
    l = lines.pop(rec); lines.insert(up, l)
elif how == 'ignore':
    lines[rec] = '\t-' + lines[rec][1:]
elif how == 'unpinned':
    lines[rec] = lines[rec].replace('POSTGRES_HOST= ROUTE_ACCESS_CONTAINER= ', '')
else:
    raise SystemExit('unknown mutation ' + how)
open(dst, 'w').write(s.replace(body, '\n'.join(lines)))
PY
  if diff -q "${REPO}/Makefile" "${dst}" >/dev/null; then bad "mutation ${name} did NOT land (staged Makefile identical)"; return 1; fi
  return 0
}
for m in remove before ignore; do
  if mutate_make "${m}" "${m}"; then
    if check_make "${W}/Makefile.${m}"; then
      bad "mutation '${m}' (reconcile line ${m}d in stack-up) still reads as wired — the static check cannot fail"
    else
      ok "mutation '${m}' goes RED (stack-up reconcile line: ${m})"
    fi
  fi
done

if mutate_make unpinned unpinned; then
  if check_pin "${W}/Makefile.unpinned" stack-up; then
    bad "mutation 'unpinned' (POSTGRES_HOST= ROUTE_ACCESS_CONTAINER= stripped from stack-up) still reads as pinned — the check cannot fail"
  else
    ok "mutation 'unpinned' goes RED (stack-up reconcile line no longer blanks POSTGRES_HOST/ROUTE_ACCESS_CONTAINER)"
  fi
fi

# no-target mutation: drop the standalone target
python3 - "${REPO}/Makefile" "${W}/Makefile.notarget" <<'PY'
import sys, re
s = open(sys.argv[1]).read()
s2 = re.sub(r'^stack-route-access-reconcile:.*?\n(?:\t.*\n)+', '', s, count=1, flags=re.M)
assert s2 != s
open(sys.argv[2], 'w').write(s2)
PY
if dry_run "${W}/Makefile.notarget" stack-route-access-reconcile | grep 'route-access-reconcile\.sh' >/dev/null; then
  bad "mutation 'notarget' still finds the standalone target — the check cannot fail"
else
  ok "mutation 'notarget' goes RED (standalone target removed)"
fi

# ps1 mutation: remove the apply line
sed '/psql .*ON_ERROR_STOP=1 -1 /d' "${PS1_SCRIPT}" > "${W}/stack-up.ps1.removed"
if diff -q "${PS1_SCRIPT}" "${W}/stack-up.ps1.removed" >/dev/null; then
  bad "ps1 mutation did NOT land"
elif ps1_ok "${W}/stack-up.ps1.removed"; then
  bad "ps1 mutation (apply line removed) still passes — the check cannot fail"
else
  ok "ps1 mutation goes RED (apply line removed)"
fi
# ps1 mutation: the pre-fix spelling of the readiness probe (embedded double quotes)
sed "s/-c ''SELECT 1'''/-c \"SELECT 1\"'/" "${PS1_SCRIPT}" > "${W}/stack-up.ps1.dquote"
if diff -q "${PS1_SCRIPT}" "${W}/stack-up.ps1.dquote" >/dev/null; then
  bad "ps1 dquote mutation did NOT land"
elif ps1_quotes_ok "${W}/stack-up.ps1.dquote"; then
  bad "ps1 dquote mutation (-c \"SELECT 1\" restored) still passes — the quoting check cannot fail"
else
  ok "ps1 dquote mutation goes RED (-c \"SELECT 1\" inside the sh -c argument)"
fi
# ps1 mutations: the EAP wrap removed (either half), and the -f path renamed
ps1_mut() {  # ps1_mut <name> <sed-expr> <check-fn> [extra arg]
  local name="$1"
  local expr="$2"
  local fn="$3"
  local dst="${W}/stack-up.ps1.${name}"
  sed "${expr}" "${PS1_SCRIPT}" > "${dst}"
  if diff -q "${PS1_SCRIPT}" "${dst}" >/dev/null; then bad "ps1 ${name} mutation did NOT land"; return; fi
  if "${fn}" "${dst}" "${@:4}"; then
    bad "ps1 ${name} mutation still passes — the check cannot fail"
  else
    ok "ps1 ${name} mutation goes RED"
  fi
}
ps1_mut no-continue "/^[[:space:]]*\$ErrorActionPreference = 'Continue'/d" ps1_eap_ok
ps1_mut no-restore  "/^[[:space:]]*\$ErrorActionPreference = \$savedEap/d"  ps1_eap_ok
ps1_mut bind-mount  "s#-f /tmp/route-access-seed.sql'#-f /docker-entrypoint-initdb.d/10-schema.sql'#" ps1_path_ok
ps1_mut no-copy     "/ cp \$SeedSql route-access-db:/d" ps1_path_ok
ps1_mut wrong-dest  "s#-1 -f /tmp/route-access-seed.sql#-1 -f /tmp/other.sql#" ps1_path_ok

# Script-flag mutations (static half; the engine half below proves the behaviour)
sed 's/ -v ON_ERROR_STOP=1 -1 </ -1 </' "${SCRIPT}" > "${W}/reconcile.no-stop.sh"
sed 's/ -v ON_ERROR_STOP=1 -1 </ -v ON_ERROR_STOP=1 </' "${SCRIPT}" > "${W}/reconcile.no-txn.sh"
for v in no-stop no-txn; do
  if diff -q "${SCRIPT}" "${W}/reconcile.${v}.sh" >/dev/null; then bad "script mutation ${v} did NOT land"; continue; fi
  line="$(grep '<"\${SQL}"' "${W}/reconcile.${v}.sh" | head -n 1)"
  if printf '%s' "${line}" | grep -- '-v ON_ERROR_STOP=1' >/dev/null && printf '%s' "${line}" | grep -E -- ' -1 ' >/dev/null; then
    bad "script mutation ${v} still reads as carrying both flags — the static check cannot fail"
  else
    ok "script mutation ${v} goes RED (static)"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════
echo "── 2) ENGINE (postgres:16-alpine) ──"
# ═══════════════════════════════════════════════════════════════════════════
MODE=""
if [ -n "${POSTGRES_HOST:-}" ]; then
  MODE=host
  command -v psql >/dev/null 2>&1 || { bad "POSTGRES_HOST=${POSTGRES_HOST} is set but psql is not installed — fail-closed, never a skip"; MODE=""; }
elif docker info >/dev/null 2>&1; then
  MODE=docker
fi
if [ -z "${MODE}" ]; then
  if [ "${ROUTE_ACCESS_RECONCILE_REQUIRE_ENGINE:-0}" = "1" ]; then
    bad "no engine (POSTGRES_HOST unset, no docker daemon) and ROUTE_ACCESS_RECONCILE_REQUIRE_ENGINE=1"
  else
    echo "     NOT RUN: no POSTGRES_HOST and no docker daemon — the engine leg is gated post-merge by .gitlab-ci.yml (postgres service) and locally by docker."
  fi
  echo "passed=${P} failed=${F}"
  [ "${F}" -eq 0 ] && [ "${P}" -ge 10 ] || exit 1
  exit 0
fi

if [ "${MODE}" = docker ]; then
  CONTAINER="ra-reconcile-guard-$$-${RANDOM}"
  if ! docker run -d --name "${CONTAINER}" \
        -e POSTGRES_DB=gateway -e POSTGRES_USER=gateway -e POSTGRES_PASSWORD=gateway \
        -v "${SQL}:/docker-entrypoint-initdb.d/10-schema.sql:ro" \
        postgres:16-alpine >/dev/null 2>"${W}/docker-run.err"; then
    bad "could not start postgres:16-alpine (${CONTAINER}): $(head -n 2 "${W}/docker-run.err" | tr '\n' ';')"
    echo "passed=${P} failed=${F}"; exit 1
  fi
  # q <sql>: one -tA query, TCP (the init-phase temp server is socket-only).
  q() { docker exec -i "${CONTAINER}" sh -c 'PGPASSWORD="${POSTGRES_PASSWORD}" exec psql -X -q -tA -h 127.0.0.1 -U gateway -d gateway -v ON_ERROR_STOP=1 -c "$1"' sh "$1"; }
  reconcile() { ROUTE_ACCESS_CONTAINER="${CONTAINER}" ROUTE_ACCESS_SQL="${ROUTE_ACCESS_SQL:-${SQL}}" timeout 300 bash "$@"; }
else
  q() { psql -X -q -tA -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT:-5432}" -U "${ROUTE_ACCESS_PG_USER:-gateway}" -d "${ROUTE_ACCESS_PG_DB:-gateway}" -v ON_ERROR_STOP=1 -c "$1"; }
  reconcile() { ROUTE_ACCESS_SQL="${ROUTE_ACCESS_SQL:-${SQL}}" timeout 300 bash "$@"; }   # POSTGRES_HOST is inherited
fi

deadline=$(( $(date +%s) + 120 ))
until q 'SELECT 1' >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    bad "engine (${MODE}) not reachable within 120s — fail-closed"
    echo "passed=${P} failed=${F}"; exit 1
  fi
  sleep 2
done

if [ "${MODE}" = host ]; then
  # A CI service starts EMPTY: the first reconcile is the first seed (the file
  # supports that too). Docker mode starts from the image's own initdb instead.
  out="$(reconcile "${SCRIPT}" 2>&1)"; rc=$?
  [ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -E 'reconcile: 0 -> [1-9][0-9]* rows' >/dev/null \
    && ok "first seed over an empty database: ${out##*reconcile: }" \
    || bad "first seed over an empty database failed (rc=${rc}): ${out}"
fi

fingerprint() {
  q "SELECT md5(coalesce(string_agg(gateway||'|'||url_pattern||'|'||role||'|'||coalesce(casdoor_user,'')||'|'||allow||'|'||coalesce(domain,'')||'|'||mfa_required, E'\n' ORDER BY gateway,url_pattern,role,coalesce(casdoor_user,''),coalesce(domain,'')),''))  FROM gateway_route_access"
}
total() { q 'SELECT count(*) FROM gateway_route_access'; }
games() { q "SELECT count(*) FROM gateway_route_access WHERE gateway='hugmesh-fe-gateway' AND url_pattern LIKE '/games/%'"; }

N0="$(total)"; FP0="$(fingerprint)"
[ "${N0}" -gt 100 ] && ok "seeded table has ${N0} rows (the real file through the real initdb path)" \
  || bad "seeded table has only ${N0} rows — the initdb seed did not run"

# S0: a reconcile over a table the seed just built is a no-op.
out="$(reconcile "${SCRIPT}" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -E "reconcile: ${N0} -> ${N0} rows \(inserted 0, deleted 0, mfa_required rewritten 0;" >/dev/null && [ "$(fingerprint)" = "${FP0}" ]; then
  ok "reconcile over a freshly seeded table is a no-op (rc=0, ${N0} -> ${N0}, nothing inserted/deleted/rewritten, fingerprint identical)"
else
  bad "reconcile over a freshly seeded table is NOT a no-op (rc=${rc}): ${out}"
fi
printf '%s' "${out}" | grep -E "^route-access reconcile: [0-9]+ -> [0-9]+ rows \(" >/dev/null && [ "$(printf '%s\n' "${out}" | wc -l)" -eq 1 ] \
  && ok "the reconciler prints exactly one count line (no row content)" \
  || bad "the reconciler printed something other than one count line: $(printf '%s' "${out}" | head -n 3 | tr '\n' ';')"

# ── The incident + the preservation/convergence matrix ──
G="$(games)"
[ "${G}" -ge 8 ] || bad "expected at least the 8 fe /games rows in the seed, found ${G}"
q "DELETE FROM gateway_route_access WHERE gateway='hugmesh-fe-gateway' AND url_pattern LIKE '/games/%'" >/dev/null
q "UPDATE gateway_route_access SET mfa_required=false WHERE gateway='hugmesh-fe-gateway' AND url_pattern='/bff/admin/**' AND role='ROLE_ADMIN'" >/dev/null
q "UPDATE gateway_route_access SET mfa_required=true  WHERE gateway='hugmesh-fe-gateway' AND url_pattern='/bff/mod/**'   AND role='ROLE_ADMIN'" >/dev/null
q "UPDATE gateway_route_access SET allow=false        WHERE gateway='hugmesh-pki-gateway' AND url_pattern='/login/**'    AND role='PUBLIC'" >/dev/null
q "INSERT INTO gateway_route_access (gateway,url_pattern,role,allow) VALUES ('hugmesh-fe-gateway','/zz-admin-added/**','ROLE_USER',true)" >/dev/null
q "INSERT INTO gateway_route_access (gateway,url_pattern,role,allow,domain,mfa_required) VALUES ('hugmesh-fe-gateway','/bff/admin/**','ROLE_ADMIN',true,'brand-x',false)" >/dev/null
[ "$(games)" -eq 0 ] || bad "setup: the fe /games rows were not deleted"

out="$(reconcile "${SCRIPT}" 2>&1)"; rc=$?
EXPECT_BEFORE=$((N0 - G + 2)); EXPECT_AFTER=$((N0 + 2))
if [ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -E "reconcile: ${EXPECT_BEFORE} -> ${EXPECT_AFTER} rows \(inserted ${G}, deleted 0, mfa_required rewritten 2;" >/dev/null; then
  ok "stale stack converges: ${EXPECT_BEFORE} -> ${EXPECT_AFTER} rows, the ${G} missing fe /games rows re-inserted, nothing deleted, 2 mfa rows re-flipped"
else
  bad "stale stack did not converge as expected (rc=${rc}; wanted ${EXPECT_BEFORE} -> ${EXPECT_AFTER}, inserted ${G}, rewritten 2): ${out}"
fi
[ "$(games)" -eq "${G}" ] && ok "the ${G} fe /games rows are back (the 2026-10-29 incident shape)" \
  || bad "fe /games rows after reconcile: $(games), expected ${G}"
[ "$(q "SELECT mfa_required FROM gateway_route_access WHERE gateway='hugmesh-fe-gateway' AND url_pattern='/bff/mod/**' AND role='ROLE_ADMIN'")" = t ] \
  && ok "PRESERVED: an admin TIGHTENING outside the blanket prefixes (fe /bff/mod/** ROLE_ADMIN mfa_required=true) survives" \
  || bad "an admin tightening outside the blanket prefixes was lost"
[ "$(q "SELECT allow FROM gateway_route_access WHERE gateway='hugmesh-pki-gateway' AND url_pattern='/login/**' AND role='PUBLIC'")" = f ] \
  && ok "PRESERVED: an admin's allow=false on a seed row (pki /login/** PUBLIC) survives — ON CONFLICT DO NOTHING never rewrites an existing row" \
  || bad "an admin's allow=false on a seed row was reverted"
[ "$(q "SELECT count(*) FROM gateway_route_access WHERE url_pattern='/zz-admin-added/**'")" = 1 ] \
  && ok "PRESERVED: an admin-ADDED row survives (nothing in the file deletes non-seed rows except the de-dup and the one '/apidocs/**' retirement)" \
  || bad "an admin-added row was deleted"
[ "$(q "SELECT mfa_required FROM gateway_route_access WHERE gateway='hugmesh-fe-gateway' AND url_pattern='/bff/admin/**' AND role='ROLE_ADMIN' AND domain IS NULL")" = t ] \
  && ok "CONVERGED (documented): an admin LOOSENING under /bff/admin (unscoped row mfa_required=false) is re-flipped true — the file's OPERATOR CAVEAT contract" \
  || bad "the blanket mfa flip did not converge the unscoped /bff/admin/** row"
[ "$(q "SELECT mfa_required FROM gateway_route_access WHERE gateway='hugmesh-fe-gateway' AND url_pattern='/bff/admin/**' AND role='ROLE_ADMIN' AND domain='brand-x'")" = t ] \
  && ok "CONVERGED (documented): a domain-scoped /bff/admin/** row is re-flipped too (the blanket is domain-blind; a scoped false row is a phantom exemption)" \
  || bad "the blanket mfa flip did not converge the domain-scoped /bff/admin/** row"
[ "$(q "SELECT count(*) FROM gateway_route_access WHERE url_pattern='/apidocs/**'")" = 0 ] \
  && ok "the misspelled '/apidocs/**' row stays retired" \
  || bad "an '/apidocs/**' row exists after reconcile"

# Re-run: a genuine no-op.
FP1="$(fingerprint)"
out="$(reconcile "${SCRIPT}" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -E "reconcile: ${EXPECT_AFTER} -> ${EXPECT_AFTER} rows \(inserted 0, deleted 0, mfa_required rewritten 0;" >/dev/null && [ "$(fingerprint)" = "${FP1}" ]; then
  ok "re-running is a no-op (rc=0, ${EXPECT_AFTER} -> ${EXPECT_AFTER}, inserted 0, rewritten 0, fingerprint identical)"
else
  bad "re-running is NOT a no-op (rc=${rc}): ${out}"
fi

# ── Failure atomicity: a SQL error exits non-zero and leaves the table untouched ──
BROKEN="${W}/broken.sql"
{ cat "${SQL}"; printf '\n-- planted by the guard\nINSERT INTO gateway_route_access (gateway) VALUES (NULL);\n'; } > "${BROKEN}"
q "DELETE FROM gateway_route_access WHERE gateway='hugmesh-fe-gateway' AND url_pattern LIKE '/games/%'" >/dev/null
NB="$(total)"; FPB="$(fingerprint)"
out="$(ROUTE_ACCESS_SQL="${BROKEN}" reconcile "${SCRIPT}" 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep 'FAIL' >/dev/null \
  && ok "a SQL error exits non-zero and says FAIL (rc=${rc})" \
  || bad "a SQL error did not fail loud (rc=${rc}): ${out}"
[ "$(total)" = "${NB}" ] && [ "$(fingerprint)" = "${FPB}" ] && [ "$(games)" -eq 0 ] \
  && ok "…and the table is UNTOUCHED (${NB} rows, fingerprint identical, the ${G} /games rows NOT half-applied) — one transaction" \
  || bad "a failed apply left the table changed: $(total) rows (was ${NB}), /games rows $(games) (expected 0)"

# Engine MUTATIONS of the reconciler (staged copies from the static leg above).
# no-txn: without -1 the seed INSERT commits before the planted error -> the
#         /games rows come back although the run FAILED (half-applied).
out="$(ROUTE_ACCESS_SQL="${BROKEN}" reconcile "${W}/reconcile.no-txn.sh" 2>&1)"; rc=$?
if [ "${rc}" -ne 0 ] && [ "$(games)" -eq "${G}" ]; then
  ok "mutation no-txn goes RED: without -1 a failed apply HALF-APPLIES (rc=${rc} but the ${G} /games rows landed)"
else
  bad "mutation no-txn did not change the outcome (rc=${rc}, /games rows $(games)) — the atomicity assertion cannot fail"
fi
q "DELETE FROM gateway_route_access WHERE gateway='hugmesh-fe-gateway' AND url_pattern LIKE '/games/%'" >/dev/null
# no-stop: without ON_ERROR_STOP psql presses on past the error, the transaction
#          is rolled back at COMMIT, and psql exits 0 -> the run reports SUCCESS.
out="$(ROUTE_ACCESS_SQL="${BROKEN}" reconcile "${W}/reconcile.no-stop.sh" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then
  ok "mutation no-stop goes RED: without ON_ERROR_STOP a failed apply exits 0 (silent failure)"
else
  bad "mutation no-stop did not change the outcome (rc=${rc}) — the fail-loud assertion cannot fail"
fi

# Restore and prove convergence once more after the failures — this time with
# ROUTE_ACCESS_SQL UNSET, so the reconciler's OWN default seed path is what runs
# (`make stack-up` never sets it; every call above passes the file explicitly).
# A default that names any file without the fe /games rows leaves them missing.
if [ "${MODE}" = docker ]; then
  out="$(env -u ROUTE_ACCESS_SQL ROUTE_ACCESS_CONTAINER="${CONTAINER}" timeout 300 bash "${SCRIPT}" 2>&1)"; rc=$?
else
  out="$(env -u ROUTE_ACCESS_SQL timeout 300 bash "${SCRIPT}" 2>&1)"; rc=$?
fi
[ "${rc}" -eq 0 ] && [ "$(games)" -eq "${G}" ] && [ "$(total)" = "${EXPECT_AFTER}" ] \
  && ok "after the failed applies a reconcile on the reconciler's DEFAULT seed path (ROUTE_ACCESS_SQL unset) converges again (${G} /games rows, ${EXPECT_AFTER} total)" \
  || bad "post-failure reconcile on the default seed path did not converge (rc=${rc}, /games rows $(games), total $(total)): ${out}"

echo "passed=${P} failed=${F}"
[ "${F}" -eq 0 ] && [ "${P}" -ge 25 ] || exit 1
exit 0

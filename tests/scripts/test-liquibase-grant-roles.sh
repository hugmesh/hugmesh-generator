#!/usr/bin/env bash
# test-liquibase-grant-roles.sh — the gate for "a service's Liquibase changelogs GRANT
# to a Postgres role that its own database bootstrap never creates".
#
# WHY THIS EXISTS. hugmesh-admin-bff-api CrashLoopBackOff'd in the kind cluster and
# could never complete startup:
#
#   Migration failed for changeset db/changelog/008-access-suspension.xml::
#     008-access-suspension-grant::hugmesh
#   Reason: ERROR: role "admin_bff" does not exist
#     [Failed SQL: GRANT SELECT, INSERT, UPDATE ON access_suspension TO admin_bff]
#
# All 97 GRANT/REVOKE statements in that repo's changelogs named `admin_bff`. The role
# exists — in the SEPARATE route-access/gateway Postgres (manifests/route-access/
# initdb/10-roles.sh), where admin-bff is only a client. admin-bff's OWN database
# bootstrap creates `adminbff_app` (manifests/admin-bff-db/initdb/10-roles.sh), which is
# also the role the app connects as. A role name had been copied across a datasource
# boundary and nothing compared the two sides.
#
# WHY IT SHIPPED, AND WHY THE [connects] AND [compose] LEGS EXIST. Every environment
# that ran the changelog outside the cluster carried a shim creating the missing role so
# the GRANT would merely RESOLVE — tests/stack/compose.local.yaml's `admin-bff-db-init`
# (NOLOGIN) and both Testcontainers harnesses in the service repo. Each took its name
# from the changelog rather than from the bootstrap, so compose and CI stayed green on a
# role the cluster did not have. Note what that means: the obvious "fix" — teach
# admin-bff-db's bootstrap to CREATE ROLE admin_bff — would have un-wedged startup while
# leaving all 97 statements granting privileges to a role nothing logs in as. Startup
# passing because a grant lands on an unused role is not a fix, so the checker also
# requires the grantee to be a role something actually CONNECTS as (control 4 plants
# exactly that placebo), and it reads compose.local.yaml itself so a locally invented
# shim role is caught in the file that invented it (controls 14-16).
#
# THE SERVICE CHECKOUTS ARE PART OF THE GATE, NOT A CONVENIENCE. The bootstraps are in
# this repo, the changelogs are in the service repos. Without them there is nothing to
# compare, so the checker exits 3 INCOMPLETE and this script FAILS rather than skipping.
#
# Negative controls: the verbatim regression, planted into a copy of the CURRENT corpus
# so it cannot go stale; the placebo fix; a bootstrap whose role script is never mounted;
# an initdb scan that matches nothing; a changelog scan that matches nothing; prose about
# GRANTs that must not be read as a GRANT; absent checkouts, which must be INCOMPLETE and
# never green; the compose shim renamed back to the role that caused the incident; and
# the safety rails below, fired on purpose against a canary tree.
#
# Offline: no cluster, no kubectl, no network; writes only into its own mktemp dirs.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${REPO}/tests/scripts/liquibase_grant_roles.py"
CLUSTER="${REPO}/specs/cluster"

# Hard-fail on absent tooling. A gate that skips because a parser is missing is the
# failure mode this repo keeps shipping.
command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available (pip install pyyaml)"; exit 1; }
[ -f "${CHECKER}" ] || { echo "  FAIL missing checker: ${CHECKER}"; exit 1; }
[ -d "${CLUSTER}" ] || { echo "  FAIL missing cluster tree: ${CLUSTER}"; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════════════
#  SAFETY RAILS — READ BEFORE ADDING A CONTROL
#
#  This script stages copies of REAL source trees and then DELETES and REWRITES files
#  inside them (control 8 runs `find -delete`; 1, 4 and 7 run `perl -pi` over every
#  matching file). Service checkouts here are routinely SYMLINKS: git worktrees live
#  that way, and the INCOMPLETE message below tells people to rely on "sibling
#  checkouts beside this repo". `cp -a` PRESERVES a symlink, and a later `find -delete`
#  or `perl -pi` whose path runs through one lands in the ORIGINAL tree.
#
#  That is not hypothetical. An earlier revision of this script, run against a source
#  root of ten symlinked checkouts, emptied a real checkout's db/changelog directory —
#  64 files gone. A test that eats the tree it is run beside gets run once.
#
#  Three independent rails now stop it, and none of them is allowed to be "probably
#  fine":
#    1. staging DEREFERENCES (cp -RL), so a staged tree holds real files, never links;
#    2. a staged tree containing any symlink at all is refused outright;
#    3. EVERY destructive command goes through a tmp_* helper that resolves its target
#       with `readlink -f` and aborts unless the result is inside ${TMP_REAL}.
#  Control 13 fires rails 2 and 3 on purpose, at a canary tree outside ${TMP}, and
#  proves the canary survives. If you add a destructive step, add it as a tmp_* call —
#  a bare `rm`, `find -delete`, `perl -i` or `>` aimed at a STAGED TREE is a bug. (The
#  canary tree control 13 builds is written directly, on purpose: it is this script's
#  own mktemp dir and the rails must see it as foreign.)
# ═══════════════════════════════════════════════════════════════════════════════════

TMP="$(mktemp -d)"
TMP_REAL="$(readlink -f -- "${TMP}")"
[ -n "${TMP_REAL}" ] && [ -d "${TMP_REAL}" ] || { echo "  FAIL mktemp -d did not resolve to a directory"; exit 1; }
trap 'rm -rf "${TMP_REAL}"' EXIT
# The canary for control 13: a SECOND mktemp dir, so it is genuinely outside ${TMP_REAL}
# and the rails must treat it as off-limits.
CANARY="$(mktemp -d)"
CANARY_REAL="$(readlink -f -- "${CANARY}")"
[ -n "${CANARY_REAL}" ] && [ -d "${CANARY_REAL}" ] || { echo "  FAIL canary mktemp -d did not resolve"; exit 1; }
case "${CANARY_REAL}/" in
  "${TMP_REAL}"/*) echo "  FAIL the canary must not live inside ${TMP_REAL}"; exit 1 ;;
esac
trap 'rm -rf "${TMP_REAL}" "${CANARY_REAL}"' EXIT
FAILED=0

die() { echo "  FAIL $*"; exit 1; }

# under_tmp <path> : rail 3. Resolve <path> through every symlink in it and abort the
# whole run unless the result is inside ${TMP_REAL}. MUST NOT be called inside a command
# substitution or a pipeline — its `exit` has to take the script down, not a subshell.
under_tmp() {
  local p="$1" real
  real="$(readlink -f -- "$p" 2>/dev/null)"
  if [ -z "${real}" ]; then
    echo "  FAIL SAFETY: refusing to act on a path that does not resolve: $p"
    exit 1
  fi
  case "${real}/" in
    "${TMP_REAL}"/*) return 0 ;;
  esac
  echo "  FAIL SAFETY: a destructive step would act on"
  echo "         $p"
  echo "       which resolves to"
  echo "         ${real}"
  echo "       OUTSIDE the scratch dir ${TMP_REAL}. That is the symlink-follow that once"
  echo "       emptied a real checkout. Aborting before anything is written."
  exit 1
}

# assert_staged_clean <dir> : rail 2. A staged tree must be inside ${TMP} and hold no
# symlink whatsoever — one link in it is a loaded gun pointed at whatever it names.
assert_staged_clean() {
  local d="$1" links
  under_tmp "${d}"
  links="$(find "${d}" -type l -print 2>/dev/null | head -5)"
  if [ -n "${links}" ]; then
    echo "  FAIL SAFETY: staged tree ${d} contains symlink(s); refusing to run destructive"
    echo "       controls against it:"
    echo "${links}" | sed 's/^/         | /'
    exit 1
  fi
}

# ── the only destructive primitives this script is allowed to use ─────────────────
tmp_delete_files() { under_tmp "$1"; find "$1" -type f -delete; }
tmp_rm_rf()        { under_tmp "$1"; rm -rf -- "$1"; }
tmp_truncate()     { under_tmp "$1"; : > "$1"; }
tmp_write()        { under_tmp "$1"; cat > "$1"; }     # content on stdin

# tmp_perl <perl-args...> --files <file...> : in-place edit, every file rail-checked.
tmp_perl() {
  local args=() f
  while [ $# -gt 0 ] && [ "$1" != "--files" ]; do args+=("$1"); shift; done
  [ "${1:-}" = "--files" ] || die "tmp_perl called without --files"
  shift
  [ $# -gt 0 ] || die "tmp_perl called with no files — the control planted nothing"
  for f in "$@"; do under_tmp "${f}"; done
  perl "${args[@]}" "$@"
}

# tmp_perl_matching <dir> <grep-pattern> <perl-expr> : rewrite every file under <dir>
# that matches. Replaces the old `grep -rl … | xargs perl -pi`, which had no idea where
# the files it was handed actually lived. Matching NOTHING is a control failure, not a
# quiet no-op.
tmp_perl_matching() {
  local dir="$1" pat="$2" expr="$3" hits=()
  under_tmp "${dir}"
  mapfile -d '' -t hits < <(grep -rlZ -- "${pat}" "${dir}" 2>/dev/null)
  [ "${#hits[@]}" -gt 0 ] || die "no file under ${dir} matches /${pat}/ — the control would plant nothing"
  tmp_perl -pi -e "${expr}" --files "${hits[@]}"
}

# ── the corpus stagers ────────────────────────────────────────────────────────────
# stage_repo <src-root> <dest-root> <repo> : copy ONE repo's changelog tree as real
# files. -L dereferences, so a symlinked checkout becomes a private copy under ${TMP}
# and the destructive controls below cannot escape into it. --preserve deliberately
# omits `links`: `cp -a` would also carry hard links in, which is not wanted either.
# Only ${CHANGELOG_REL} is staged because that is the only path the checker opens — and
# the only path CI materialises (the clone loop sparse-checkouts exactly that directory).
stage_repo() {
  local sroot="$1" dest="$2" repo="$3"
  mkdir -p "${dest}/${repo}/${CHANGELOG_PARENT}" || die "cannot create ${dest}/${repo}"
  cp -RL --preserve=mode,timestamps \
     "${sroot}/${repo}/${CHANGELOG_REL}" "${dest}/${repo}/${CHANGELOG_REL}" \
    || die "could not stage ${sroot}/${repo}/${CHANGELOG_REL} (dangling symlink? unreadable?)"
}

# stage_src <dest> [src-root] : the whole declared corpus, as real files.
stage_src() {
  local dest="$1" sroot="${2:-${SRC}}" r
  mkdir -p "${dest}"; under_tmp "${dest}"
  for r in ${REPOS}; do stage_repo "${sroot}" "${dest}" "${r}"; done
  assert_staged_clean "${dest}"
}

# stage_cluster <dest> : a copy of specs/cluster, likewise dereferenced and checked.
stage_cluster() {
  mkdir -p "$1"; under_tmp "$1"
  cp -RL --preserve=mode,timestamps "${CLUSTER}/." "$1/" || die "could not stage ${CLUSTER}"
  assert_staged_clean "$1"
}

# stage_compose <dest-file> : a copy of the local-stack compose file.
stage_compose() {
  under_tmp "$(dirname "$1")"
  cp -L --preserve=mode,timestamps "${COMPOSE}" "$1" || die "could not stage ${COMPOSE}"
  assert_staged_clean "$(dirname "$1")"
}

# expect <rc> <label> -- <cmd...>   : run, compare rc, print the output on mismatch
expect() {
  local want="$1" label="$2"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "${rc}" -eq "${want}" ]; then
    echo "  ok   ${label} (rc=${rc})"
  else
    echo "  FAIL ${label}: expected rc=${want}, got rc=${rc}"
    echo "${out}" | sed 's/^/         | /'
    FAILED=1
  fi
}

# expect_out <rc> <pattern> <label> -- <cmd...> : as `expect`, and the output must also
# match <pattern>. A control that goes red for the wrong reason is a control that is not
# testing what its label claims.
expect_out() {
  local want="$1" pat="$2" label="$3"; shift 4
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "${rc}" -eq "${want}" ] && printf '%s' "${out}" | grep -q -- "${pat}"; then
    echo "  ok   ${label} (rc=${rc}, matched /${pat}/)"
  else
    echo "  FAIL ${label}: expected rc=${want} and output matching /${pat}/, got rc=${rc}"
    echo "${out}" | sed 's/^/         | /'
    FAILED=1
  fi
}

echo "== liquibase GRANT-role gate =="

# ── 0. Resolve the corpus. Absent checkouts are a FAILURE, never a skip. ──────────
echo "-- positive: this repo's bootstraps must satisfy every service's changelogs --"
OUT="$(python3 "${CHECKER}" "${CLUSTER}" 2>&1)"; RC=$?
echo "${OUT}" | sed 's/^/  /'
if [ "${RC}" -eq 3 ]; then
  echo
  echo "== liquibase GRANT-role gate: INCOMPLETE =="
  echo "   This gate compares the service repos' changelogs against this repo's DB"
  echo "   bootstraps. Without the checkouts it compares nothing. Set SERVICE_SRC_ROOT"
  echo "   (CI clones them; locally, sibling checkouts beside this repo are found"
  echo "   automatically — symlinked checkouts are fine, the controls copy through them)."
  echo "   A green run without them would be a lie, so this is a FAIL."
  exit 1
fi
[ "${RC}" -eq 0 ] || { echo "  FAIL the tree itself violates the invariant (rc=${RC})"; FAILED=1; }

# The resolved source root, reused by the controls below.
SRC="$(python3 - "${CHECKER}" "${CLUSTER}" <<'PY'
import subprocess, sys, re
out = subprocess.run([sys.executable, sys.argv[1], sys.argv[2]],
                     capture_output=True, text=True).stdout
m = re.search(r"sources: (.+)$", out, re.M)
print(m.group(1).strip() if m else "")
PY
)"
[ -n "${SRC}" ] && [ -d "${SRC}" ] || die "could not resolve the service-source root"

# The declared repo set and the paths the checker reads, both taken FROM THE CHECKER.
REPOS="$(python3 "${CHECKER}" "${CLUSTER}" --list-repos)"
[ -n "${REPOS}" ] || die "--list-repos produced nothing"
read -r CHANGELOG_REL COMPOSE_REL <<<"$(python3 - "${CHECKER}" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("chk", sys.argv[1])
chk = importlib.util.module_from_spec(spec); spec.loader.exec_module(chk)
print(chk.CHANGELOG_REL, chk.COMPOSE_REL)
PY
)"
[ -n "${CHANGELOG_REL}" ] && [ -n "${COMPOSE_REL}" ] || die "could not read CHANGELOG_REL/COMPOSE_REL from the checker"
CHANGELOG_PARENT="$(dirname "${CHANGELOG_REL}")"
COMPOSE="${REPO}/${COMPOSE_REL}"
[ -f "${COMPOSE}" ] || die "missing local-stack compose file: ${COMPOSE}"
echo "  --   controls stage copies of ${SRC} (${CHANGELOG_REL} per repo) and ${COMPOSE_REL}"

# The service that actually carries GRANTs, and the role they target, both DERIVED —
# a hard-coded name here would rot the moment the corpus moved.
#
# The pivot is chosen from the DECLARED repo set (--list-repos), in its order, NEVER by
# scanning the directory. Scanning was wrong: a source root is allowed to hold unrelated
# siblings, and one that sorts before `hugmesh-*` and happens to contain a GRANT — a
# stale clone, say — would become the pivot, after which controls 1/4/7/8/11 would
# delete and rewrite files in something that is not a service of this platform at all.
read -r GSVC GROLE <<<"$(python3 - "${CHECKER}" "${SRC}" ${REPOS} <<'PY'
import sys, pathlib, importlib.util
spec = importlib.util.spec_from_file_location("chk", sys.argv[1])
chk = importlib.util.module_from_spec(spec); spec.loader.exec_module(chk)
root = pathlib.Path(sys.argv[2])
for repo in sys.argv[3:]:            # the declared set only, in --list-repos order
    src = root / repo / chk.CHANGELOG_REL
    if not src.is_dir():
        print("ABSENT", repo); break
    roles, stmts, _ = chk.granted_roles(src)
    if roles:
        print(repo, sorted(roles)[0]); break
PY
)"
[ "${GSVC}" = "ABSENT" ] && die "declared repo '${GROLE}' has no ${CHANGELOG_REL} under ${SRC} — the pivot cannot be chosen, and substituting whatever else is lying around is how a control ends up rewriting a stranger's files"
[ -n "${GSVC}" ] && [ -n "${GROLE}" ] || die "no DECLARED service carries a GRANT — the controls would test nothing"
PIVOT_DECLARED=0
for r in ${REPOS}; do [ "${r}" = "${GSVC}" ] && PIVOT_DECLARED=1; done
[ "${PIVOT_DECLARED}" -eq 1 ] || die "pivot '${GSVC}' is not in the declared repo set — refusing to mutate it"
echo "  --   controls pivot on ${GSVC}, which grants to '${GROLE}'"

# ── 1. THE VERBATIM REGRESSION ───────────────────────────────────────────────────
# Rename the granted role to the one the bug actually used. Nothing creates it, so the
# in-cluster Liquibase run would abort exactly as it did on 2026-08-06.
C1="${TMP}/c1"; stage_src "${C1}"
tmp_perl_matching "${C1}/${GSVC}" "\b${GROLE}\b" "s/\b${GROLE}\b/admin_bff/g"
expect_out 1 "\[created\] GRANT/REVOKE to role 'admin_bff'" \
  "regression: GRANT to a role no bootstrap creates (admin_bff) is caught" -- \
  python3 "${CHECKER}" "${CLUSTER}" --service-src "${C1}"

# ── 2. THE SAME BUG IN ANY OTHER SERVICE ─────────────────────────────────────────
# The fleet-wide half: plant a GRANT to an uncreated role in a service that has none
# today, and require it to be caught too. This is the leg that stops the next
# admin-bff from being a different repo.
C2="${TMP}/c2"; stage_src "${C2}"
VICTIM="$(for r in ${REPOS}; do [ "$r" = "${GSVC}" ] || { echo "$r"; break; }; done)"
VDIR="$(find "${C2}/${VICTIM}" -name '*.xml' | head -1)"
[ -n "${VDIR}" ] || die "no changelog to plant into for ${VICTIM}"
tmp_perl -0pi -e 's#(</databaseChangeLog>)#    <changeSet id="planted-grant" author="test">\n        <sql>GRANT SELECT ON some_table TO totally_invented_role</sql>\n    </changeSet>\n$1#' --files "${VDIR}"
expect_out 1 "totally_invented_role" \
  "fleet-wide: the same bug planted in ${VICTIM} is caught" -- \
  python3 "${CHECKER}" "${CLUSTER}" --service-src "${C2}"

# ── 3. PROSE IS NOT SQL ──────────────────────────────────────────────────────────
# Several repos' changelogs discuss application-level grants in <comment> and XML
# comments ("a GRANT giving a USER read access"). A grep-for-GRANT gate would read
# those as SQL. Adding more such prose must stay green.
C3="${TMP}/c3"; stage_src "${C3}"
PDIR="$(find "${C3}/${VICTIM}" -name '*.xml' | head -1)"
[ -n "${PDIR}" ] || die "no changelog to plant prose into for ${VICTIM}"
tmp_perl -0pi -e 's#(</databaseChangeLog>)#    <!-- a GRANT giving a USER access TO wholly_fictional_role -->\n    <changeSet id="planted-prose" author="test">\n        <comment>GRANT SELECT ON t TO another_fictional_role</comment>\n        <sql>CREATE TABLE planted_prose (id int)</sql>\n    </changeSet>\n$1#' --files "${PDIR}"
expect 0 "prose about GRANTs in comments is not mistaken for a GRANT" -- \
  python3 "${CHECKER}" "${CLUSTER}" --service-src "${C3}"

# ── 4. THE PLACEBO FIX ───────────────────────────────────────────────────────────
# Take the regression from control 1 and "fix" it the tempting way: teach the bootstrap
# to create `admin_bff`. Startup would pass; the grants would land on a role nothing
# logs in as. [connects] must keep this red.
C4="${TMP}/c4"; C4C="${TMP}/c4-cluster"; stage_src "${C4}"; stage_cluster "${C4C}"
tmp_perl_matching "${C4}/${GSVC}" "\b${GROLE}\b" "s/\b${GROLE}\b/admin_bff/g"
tmp_perl -pi -e "s/(CREATE ROLE ${GROLE} LOGIN)/CREATE ROLE admin_bff LOGIN NOSUPERUSER; \$1/" \
  --files "${C4C}/manifests/admin-bff-db/initdb/10-roles.sh"
grep -q "CREATE ROLE admin_bff" "${C4C}/manifests/admin-bff-db/initdb/10-roles.sh" \
  || { echo "  FAIL control 4 failed to plant the placebo role"; FAILED=1; }
expect_out 1 "\[connects\] GRANT/REVOKE to role 'admin_bff'" \
  "placebo: creating the role but never connecting as it stays red" -- \
  python3 "${CHECKER}" "${C4C}" --service-src "${C4}"

# ── 5. A BOOTSTRAP THAT NEVER RUNS ───────────────────────────────────────────────
# The role script exists in the tree but is not published into the initdb ConfigMap, so
# Postgres never executes it and the role is never created.
C5C="${TMP}/c5-cluster"; stage_cluster "${C5C}"
tmp_perl -0pi -e 's/^\s*- initdb\/10-roles\.sh\n//m' --files "${C5C}/manifests/admin-bff-db/kustomization.yaml"
grep -q "initdb/10-roles.sh" "${C5C}/manifests/admin-bff-db/kustomization.yaml" \
  && { echo "  FAIL control 5 failed to unpublish the role script"; FAILED=1; }
expect_out 1 "\[mounted\]" "unmounted: a role script no ConfigMap publishes is caught" -- \
  python3 "${CHECKER}" "${C5C}"

# ── 6. VACUITY — THE INITDB SCAN MATCHES NOTHING ─────────────────────────────────
# Empty the bootstrap. The checker must refuse rather than conclude "no roles granted
# to anything missing".
C6C="${TMP}/c6-cluster"; stage_cluster "${C6C}"
tmp_truncate "${C6C}/manifests/admin-bff-db/initdb/10-roles.sh"
tmp_perl -pi -e 's/^(\s+)- \{ name: POSTGRES_USER.*$/$1- { name: POSTGRES_USER_DISABLED, value: "x" }/' \
  --files "${C6C}/manifests/admin-bff-db/deployment.yaml"
tmp_perl -0pi -e 's/name: POSTGRES_USER\n(\s+)value: "adminbff"/name: POSTGRES_USER_DISABLED\n$1value: "adminbff"/' \
  --files "${C6C}/manifests/admin-bff-db/deployment.yaml"
expect 1 "vacuity: an initdb scan that finds no role FAILS rather than passes" -- \
  python3 "${CHECKER}" "${C6C}"

# ── 7. VACUITY — THE CHANGELOG SCAN MATCHES NOTHING ──────────────────────────────
# Strip every GRANT from the whole corpus. A gate that certifies a corpus containing no
# GRANT at all cannot distinguish "clean" from "my parser broke".
C7="${TMP}/c7"; stage_src "${C7}"
tmp_perl_matching "${C7}/${GSVC}" "\b${GROLE}\b" 's/\bGRANT\b/XGRANTX/g; s/\bREVOKE\b/XREVOKEX/g'
expect_out 1 "\[vacuity\]" \
  "vacuity: a corpus with zero GRANT statements FAILS rather than passes" -- \
  python3 "${CHECKER}" "${CLUSTER}" --service-src "${C7}"

# ── 8. VACUITY — NO CHANGELOG FILES AT ALL ───────────────────────────────────────
C8="${TMP}/c8"; stage_src "${C8}"
tmp_delete_files "${C8}/${GSVC}/${CHANGELOG_REL}"
expect 3 "vacuity: a service with no changelog files is INCOMPLETE, not green" -- \
  python3 "${CHECKER}" "${CLUSTER}" --service-src "${C8}"

# ── 9. ABSENT CHECKOUTS ARE INCOMPLETE, NEVER GREEN ──────────────────────────────
C9="${TMP}/c9"; mkdir -p "${C9}"
expect 3 "absent checkouts are INCOMPLETE (rc 3), never a silent pass" -- \
  env -u SERVICE_SRC_ROOT python3 "${CHECKER}" "${CLUSTER}" --service-src "${C9}"

# ── 10. A PARTIAL CORPUS IS ALSO INCOMPLETE ──────────────────────────────────────
C10="${TMP}/c10"; stage_src "${C10}"; tmp_rm_rf "${C10}/${GSVC}"
expect 3 "a corpus missing one service is INCOMPLETE, not a pass on the rest" -- \
  env -u SERVICE_SRC_ROOT python3 "${CHECKER}" "${CLUSTER}" --service-src "${C10}"

# ── 11. AN UNPARSEABLE CHANGELOG ABORTS ──────────────────────────────────────────
C11="${TMP}/c11"; stage_src "${C11}"
C11XML="$(find "${C11}/${GSVC}" -name '*.xml' | head -1)"
[ -n "${C11XML}" ] || die "control 11 found no changelog to corrupt under ${C11}/${GSVC}"
printf '<databaseChangeLog><changeSet></databaseChangeLog>' | tmp_write "${C11XML}"
expect 2 "an unparseable changelog ABORTS (rc 2) rather than being skipped" -- \
  python3 "${CHECKER}" "${CLUSTER}" --service-src "${C11}"

# ── 12. NO SERVICE DISCOVERED ────────────────────────────────────────────────────
C12C="${TMP}/c12-cluster"; mkdir -p "${C12C}/manifests"
expect 3 "a cluster tree with no Liquibase datasource is INCOMPLETE, not green" -- \
  python3 "${CHECKER}" "${C12C}"

# ── 13. THE SAFETY RAILS THEMSELVES ──────────────────────────────────────────────
# Rails that are never fired are decoration. This reproduces the exact layout that once
# destroyed a real checkout — a source root whose repo entry is a SYMLINK to a tree
# elsewhere — against a canary in a DIFFERENT mktemp dir, and requires that (a) staging
# through the symlink yields real files, (b) the rails refuse a staged tree that still
# contains a link, (c) control 8's destructive step aborts when aimed through one, and
# (d) the canary is byte-identical afterwards.
# Two independent escape routes are planted: the CHECKOUT itself is a symlink (the shape
# that did the damage), and there is a further symlink INSIDE the changelog tree pointing
# at a file outside it (the shape `cp -a` would carry into the staged copy).
mkdir -p "${CANARY_REAL}/victim/${CHANGELOG_REL}"
printf 'do not touch me\n' > "${CANARY_REAL}/outside.sql"
printf '<databaseChangeLog/>\n' > "${CANARY_REAL}/victim/${CHANGELOG_REL}/changelog.xml"
printf 'GRANT SELECT ON t TO canary;\n' > "${CANARY_REAL}/victim/${CHANGELOG_REL}/roles.sql"
ln -s "${CANARY_REAL}/outside.sql" "${CANARY_REAL}/victim/${CHANGELOG_REL}/linked.sql"
canary_state() { find "${CANARY_REAL}" \( -type f -o -type l \) -print0 | sort -z | xargs -0 sha256sum | sha256sum; }
CANARY_BEFORE="$(canary_state)"
CANARY_N_BEFORE="$(find "${CANARY_REAL}" \( -type f -o -type l \) | wc -l)"

C13FARM="${TMP}/c13-farm"; mkdir -p "${C13FARM}"
ln -s "${CANARY_REAL}/victim" "${C13FARM}/victim"          # the layout that did the damage

# (a) staging DEREFERENCES: the staged copy holds real files, and the link that pointed
#     out of the tree became a plain file, so a later rewrite cannot travel down it.
C13S="${TMP}/c13-staged"; mkdir -p "${C13S}"
stage_repo "${C13FARM}" "${C13S}" "victim"
if [ -z "$(find "${C13S}" -type l -print)" ] \
   && [ -f "${C13S}/victim/${CHANGELOG_REL}/roles.sql" ] \
   && [ -f "${C13S}/victim/${CHANGELOG_REL}/linked.sql" ]; then
  echo "  ok   rails: staging a SYMLINKED checkout (and a link inside it) yields real files"
else
  echo "  FAIL rails: staging a symlinked checkout did not dereference"; FAILED=1
fi
# …and rewriting the staged copy really does stay in the staged copy
tmp_perl_matching "${C13S}/victim" "do not touch me" 's/do not touch me/REWRITTEN/g'
if grep -q REWRITTEN "${C13S}/victim/${CHANGELOG_REL}/linked.sql" \
   && grep -q "do not touch me" "${CANARY_REAL}/outside.sql"; then
  echo "  ok   rails: a rewrite lands in the staged copy, not down the link it replaced"
else
  echo "  FAIL rails: the rewrite escaped the staged copy"; FAILED=1
fi

# (b) a staged tree that still holds a symlink is refused
( assert_staged_clean "${C13FARM}" ) >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "  ok   rails: a staged tree containing a symlink is refused outright"
else
  echo "  FAIL rails: a staged tree containing a symlink was accepted"; FAILED=1
fi

# (c) the verbatim destructive step of control 8, aimed through that symlink, aborts
( tmp_delete_files "${C13FARM}/victim/${CHANGELOG_REL}" ) >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "  ok   rails: 'find -delete' through a symlink to a tree outside \$TMP aborts"
else
  echo "  FAIL rails: the destructive step ran through a symlink out of \$TMP"; FAILED=1
fi
# …and the same for the rewrite step, which is how controls 1/4/7 could have done it
( tmp_perl_matching "${C13FARM}/victim" "GRANT" 's/GRANT/XX/g' ) >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "  ok   rails: an in-place rewrite through that symlink aborts too"
else
  echo "  FAIL rails: the rewrite step ran through a symlink out of \$TMP"; FAILED=1
fi

# (d) the canary is untouched — the whole point
if [ "$(canary_state)" = "${CANARY_BEFORE}" ] && [ "$(find "${CANARY_REAL}" \( -type f -o -type l \) | wc -l)" = "${CANARY_N_BEFORE}" ]; then
  echo "  ok   rails: the canary tree outside \$TMP is byte-identical (${CANARY_N_BEFORE} files)"
else
  echo "  FAIL rails: THE CANARY WAS MODIFIED — the rails do not hold"; FAILED=1
fi

# ── 14. THE COMPOSE SHIM, RENAMED BACK TO THE ROLE THAT CAUSED THE INCIDENT ──────
# compose.local.yaml used to create `admin_bff` itself, so the changelog's GRANT
# resolved locally and `make stack-up` was green while the cluster had no such role.
# [compose] must call that out in the file that invented it.
C14="${TMP}/c14"; mkdir -p "${C14}"
stage_compose "${C14}/compose.local.yaml"
tmp_perl -pi -e "s/\b${GROLE}\b/admin_bff/g" --files "${C14}/compose.local.yaml"
grep -q "CREATE ROLE admin_bff" "${C14}/compose.local.yaml" \
  || { echo "  FAIL control 14 failed to plant the pre-fix compose shim"; FAILED=1; }
expect_out 1 "\[compose\].*creates role 'admin_bff'" \
  "compose: a shim role the cluster bootstrap never creates is caught" -- \
  python3 "${CHECKER}" "${CLUSTER}" --compose "${C14}/compose.local.yaml"

# ── 15. A GRANT THE LOCAL STACK COULD NEVER RUN ──────────────────────────────────
# Delete the shim outright. The changelogs still grant to `adminbff_app`; compose's
# admin-bff-db then only has its owner, so `make stack-up` would abort — and a gate that
# only read the cluster would have called that green.
C15="${TMP}/c15"; mkdir -p "${C15}"
stage_compose "${C15}/compose.local.yaml"
tmp_perl -0pi -e "s/^[ \t]*CREATE ROLE ${GROLE} NOLOGIN;\n//m" --files "${C15}/compose.local.yaml"
grep -q "CREATE ROLE ${GROLE}" "${C15}/compose.local.yaml" \
  && { echo "  FAIL control 15 failed to remove the compose shim"; FAILED=1; }
expect_out 1 "\[compose\] ${GSVC} grants to ${GROLE}" \
  "compose: a granted role the local stack never creates is caught" -- \
  python3 "${CHECKER}" "${CLUSTER}" --compose "${C15}/compose.local.yaml"

# ── 16. NO COMPOSE FILE IS INCOMPLETE, NOT GREEN ─────────────────────────────────
expect_out 3 "no local-stack compose file" \
  "an unreadable local stack is INCOMPLETE (rc 3), never a silent pass" -- \
  python3 "${CHECKER}" "${CLUSTER}" --compose "${TMP}/there-is-no-compose-here.yaml"

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "== liquibase GRANT-role gate: PASS =="
  exit 0
fi
echo "== liquibase GRANT-role gate: FAIL =="
exit 1
